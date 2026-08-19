// Command tfboundary-lint fails if any DIALED-authored IAM role is minted
// without a permissions_boundary.
//
// Why this exists
// ---------------
// The bootstrap deploy role's IAM policy gates iam:CreateRole (and the other
// role-mutation actions) on role/dialed/${project_name}-* with a required
// iam:PermissionsBoundary condition. So every IAM role the deploy role creates
// — everything in the shared tier, the stack tier, and the modules those
// consume — MUST declare a permissions_boundary, or the apply AccessDenies.
//
// That rule previously lived only as prose (a comment in stack/main.tf). The
// shared-tier cleanup Lambda skipped it and would have broken every shared
// apply. This linter turns the prose into a gate.
//
// What is checked
// ---------------
// For every *.tf under the given root (default skill/templates/terraform),
// excluding the bootstrap tier and any vendored .terraform/ cache, each
// `resource "aws_iam_role"` block must set a non-empty permissions_boundary.
//
// The bootstrap tier is exempt on purpose: its `deploy` role is minted by the
// bootstrap/admin principal (not by the deploy role) and is the very role the
// boundary constrains — self-bounding it would be wrong.
//
// The linter fails closed: a .tf it cannot parse is a .tf it cannot certify,
// so a parse error is a lint failure.
package main

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/hashicorp/hcl/v2/hclparse"
	"github.com/hashicorp/hcl/v2/hclsyntax"
)

const defaultRoot = "skill/templates/terraform"

type violation struct {
	file   string
	line   int
	role   string
	reason string
}

func main() {
	root := defaultRoot
	if len(os.Args) > 1 {
		root = os.Args[1]
	}

	var violations []violation
	checked := 0

	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			// Skip vendored module caches — those roles are upstream code we
			// govern via the permissions_boundary variable we pass into them.
			if d.Name() == ".terraform" {
				return fs.SkipDir
			}
			// Exempt the bootstrap tier (see package doc).
			if rel, rerr := filepath.Rel(root, path); rerr == nil && rel == "bootstrap" {
				return fs.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(path, ".tf") {
			return nil
		}
		vs, roleCount, lerr := lintFile(path)
		if lerr != nil {
			violations = append(violations, violation{file: path, line: 1, reason: lerr.Error()})
			return nil
		}
		checked += roleCount
		violations = append(violations, vs...)
		return nil
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "tfboundary-lint: walking %s: %v\n", root, err)
		os.Exit(2)
	}

	if len(violations) > 0 {
		fmt.Fprintf(os.Stderr, "tfboundary-lint: %d IAM role(s) missing a permissions_boundary:\n", len(violations))
		for _, v := range violations {
			if v.role != "" {
				fmt.Fprintf(os.Stderr, "  ✗ %s:%d  aws_iam_role.%s — %s\n", v.file, v.line, v.role, v.reason)
			} else {
				fmt.Fprintf(os.Stderr, "  ✗ %s:%d — %s\n", v.file, v.line, v.reason)
			}
		}
		fmt.Fprintln(os.Stderr, "\nEvery role the deploy role creates falls under role/dialed/${project_name}-* and")
		fmt.Fprintln(os.Stderr, "must set permissions_boundary = <boundary arn> (local/var). See tools/tfboundary-lint.")
		os.Exit(1)
	}

	fmt.Printf("✓ tfboundary-lint: %d IAM role(s) checked, all bounded (bootstrap tier exempt)\n", checked)
}

// lintFile parses one .tf file and returns any unbounded aws_iam_role blocks,
// the number of role blocks inspected, and a parse error (fail closed).
func lintFile(path string) ([]violation, int, error) {
	src, err := os.ReadFile(path)
	if err != nil {
		return nil, 0, err
	}
	return lintSource(path, src)
}

func lintSource(filename string, src []byte) ([]violation, int, error) {
	parser := hclparse.NewParser()
	file, diags := parser.ParseHCL(src, filename)
	if diags.HasErrors() {
		return nil, 0, fmt.Errorf("parse error: %s", diags.Error())
	}
	body, ok := file.Body.(*hclsyntax.Body)
	if !ok {
		return nil, 0, fmt.Errorf("unexpected body type %T", file.Body)
	}

	var violations []violation
	roleCount := 0
	for _, block := range body.Blocks {
		if block.Type != "resource" || len(block.Labels) < 2 || block.Labels[0] != "aws_iam_role" {
			continue
		}
		roleCount++
		role := block.Labels[1]
		line := block.TypeRange.Start.Line

		attr, present := block.Body.Attributes["permissions_boundary"]
		switch {
		case !present:
			violations = append(violations, violation{filename, line, role, "no permissions_boundary set"})
		case isTriviallyEmpty(attr.Expr):
			violations = append(violations, violation{filename, line, role, "permissions_boundary is null or empty"})
		}
	}
	return violations, roleCount, nil
}

// isTriviallyEmpty reports whether an expression is a constant null or empty
// string — a permissions_boundary that is present in name only. Anything that
// references a variable or local (local.x, var.y, "${...}") fails constant
// evaluation and is treated as a real value.
func isTriviallyEmpty(expr hclsyntax.Expression) bool {
	v, diags := expr.Value(nil)
	if diags.HasErrors() {
		return false // references something outside this file — assume real
	}
	if v.IsNull() {
		return true
	}
	if v.Type().FriendlyName() == "string" && v.AsString() == "" {
		return true
	}
	return false
}
