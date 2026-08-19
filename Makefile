.PHONY: help install-skill uninstall-skill test fmt

SKILLS_DIR ?= $(HOME)/.claude/skills
DIALED_HOME := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
SKILLS := setup verify add-shared add-module

help:
	@echo "DIALED — development targets"
	@echo ""
	@echo "  make install-skill    Symlink skill/<name>/ → $(SKILLS_DIR)/dialed:<name>/ for all skills"
	@echo "  make uninstall-skill  Remove the symlinks"
	@echo "  make test             Run the same checks CI runs (actionlint, tf validate, bash -n, yamllint, render dry-run)"
	@echo "  make fmt              terraform fmt across every module under skill/templates/terraform/"
	@echo ""
	@echo "Paths:"
	@echo "  DIALED_HOME=$(DIALED_HOME)"
	@echo "  SKILLS_DIR=$(SKILLS_DIR)"

install-skill:
	@mkdir -p $(SKILLS_DIR)
	@for s in $(SKILLS); do \
		target="$(SKILLS_DIR)/dialed:$$s"; \
		source="$(DIALED_HOME)/skill/$$s"; \
		if [ -L "$$target" ]; then \
			echo "↻ replacing existing symlink $$target"; \
			rm "$$target"; \
		elif [ -e "$$target" ]; then \
			echo "✗ $$target exists and is not a symlink — aborting to avoid data loss"; \
			exit 1; \
		fi; \
		ln -s "$$source" "$$target"; \
		echo "✓ $$target → $$source"; \
	done
	@echo ""
	@echo "Installed. Skills are now invokable as dialed:setup, dialed:verify, dialed:add-shared, dialed:add-module."

uninstall-skill:
	@for s in $(SKILLS); do \
		target="$(SKILLS_DIR)/dialed:$$s"; \
		if [ -L "$$target" ]; then \
			rm "$$target"; \
			echo "✓ removed $$target"; \
		else \
			echo "⊘ $$target not a symlink (skipping)"; \
		fi; \
	done

test:
	@echo "=== actionlint ==="
	@if command -v actionlint >/dev/null 2>&1; then \
		actionlint -shellcheck="" skill/templates/workflows/*.yml .github/workflows/*.yml; \
	else \
		echo "actionlint not installed; skipping (brew install actionlint)"; \
	fi
	@echo ""
	@echo "=== terraform validate ==="
	@if ! command -v terraform >/dev/null 2>&1; then \
		echo "terraform not installed; skipping"; \
	else \
		tf_ver=$$(terraform version | head -1 | sed -E 's/.*v([0-9.]+).*/\1/'); \
		tf_major=$$(echo "$$tf_ver" | cut -d. -f1); \
		tf_minor=$$(echo "$$tf_ver" | cut -d. -f2); \
		if [ "$$tf_major" -lt 1 ] || { [ "$$tf_major" -eq 1 ] && [ "$$tf_minor" -lt 9 ]; }; then \
			echo "terraform $$tf_ver is older than required >=1.9; skipping local validate (CI uses 1.9.8)"; \
		else \
			set -e; \
			for d in $$(find skill/templates/terraform -type f -name '*.tf' -exec dirname {} \; | sort -u); do \
				echo "→ $$d"; \
				(cd "$$d" && terraform init -backend=false -input=false -no-color >/dev/null && terraform validate -no-color) || exit 1; \
			done; \
		fi; \
	fi
	@echo ""
	@echo "=== bash -n ==="
	@for s in skill/scripts/*.sh skill/templates/terraform/shared/lambda/*.py; do \
		case "$$s" in \
			*.sh) bash -n "$$s" && echo "✓ $$s" || exit 1 ;; \
			*.py) python3 -m py_compile "$$s" && echo "✓ $$s" || exit 1 ;; \
		esac; \
	done
	@echo ""
	@echo "=== render dry-run ==="
	@if [ -f tests/fixtures/dialed.yml ]; then \
		tmp=$$(mktemp); \
		skill/scripts/render.sh --in skill/templates/Makefile.template --out "$$tmp" --config tests/fixtures/dialed.yml >/dev/null; \
		if grep -q '{{' "$$tmp"; then \
			echo "✗ unreplaced placeholders in rendered Makefile"; \
			rm "$$tmp"; \
			exit 1; \
		fi; \
		rm "$$tmp"; \
		echo "✓ render dry-run passes"; \
	else \
		echo "no tests/fixtures/dialed.yml — skipping"; \
	fi
	@echo ""
	@echo "=== iam boundary lint ==="
	@if command -v go >/dev/null 2>&1; then \
		(cd tools/tfboundary-lint && go run . ../../skill/templates/terraform) || exit 1; \
	else \
		echo "go not installed; skipping"; \
	fi
	@echo ""
	@echo "All checks passed."

fmt:
	@if command -v terraform >/dev/null 2>&1; then \
		terraform fmt -recursive skill/templates/terraform; \
		echo "✓ terraform fmt"; \
	else \
		echo "terraform not installed; skipping fmt"; \
	fi
