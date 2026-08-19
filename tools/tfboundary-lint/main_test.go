package main

import "testing"

func TestLintSource(t *testing.T) {
	cases := []struct {
		name       string
		src        string
		wantViol   int
		wantChecks int
	}{
		{
			name: "bounded role passes",
			src: `resource "aws_iam_role" "ok" {
  name                 = "x"
  path                 = "/dialed/"
  permissions_boundary = local.permissions_boundary_arn
}`,
			wantViol: 0, wantChecks: 1,
		},
		{
			name: "bounded via var passes",
			src: `resource "aws_iam_role" "ok" {
  permissions_boundary = var.permissions_boundary_arn
}`,
			wantViol: 0, wantChecks: 1,
		},
		{
			name: "missing boundary is flagged",
			src: `resource "aws_iam_role" "bad" {
  name = "x"
  path = "/dialed/"
}`,
			wantViol: 1, wantChecks: 1,
		},
		{
			name: "null boundary is flagged",
			src: `resource "aws_iam_role" "bad" {
  permissions_boundary = null
}`,
			wantViol: 1, wantChecks: 1,
		},
		{
			name: "empty-string boundary is flagged",
			src: `resource "aws_iam_role" "bad" {
  permissions_boundary = ""
}`,
			wantViol: 1, wantChecks: 1,
		},
		{
			name: "non-role resource is ignored",
			src: `resource "aws_lambda_function" "f" {
  function_name = "x"
}`,
			wantViol: 0, wantChecks: 0,
		},
		{
			name: "role with jsonencode braces still parses and passes",
			src: `resource "aws_iam_role" "ok" {
  permissions_boundary = local.b
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow" }]
  })
}`,
			wantViol: 0, wantChecks: 1,
		},
		{
			name: "two roles, one unbounded",
			src: `resource "aws_iam_role" "ok" {
  permissions_boundary = local.b
}
resource "aws_iam_role" "bad" {
  name = "y"
}`,
			wantViol: 1, wantChecks: 2,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			vs, checks, err := lintSource("test.tf", []byte(tc.src))
			if err != nil {
				t.Fatalf("unexpected parse error: %v", err)
			}
			if len(vs) != tc.wantViol {
				t.Errorf("violations = %d, want %d (%v)", len(vs), tc.wantViol, vs)
			}
			if checks != tc.wantChecks {
				t.Errorf("roles checked = %d, want %d", checks, tc.wantChecks)
			}
		})
	}
}

func TestLintSourceFailsClosedOnParseError(t *testing.T) {
	_, _, err := lintSource("bad.tf", []byte(`resource "aws_iam_role" "x" {`))
	if err == nil {
		t.Fatal("expected a parse error for malformed HCL, got nil")
	}
}
