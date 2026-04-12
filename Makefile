.PHONY: help install-skill uninstall-skill test

help:
	@echo "DIALED — development targets"
	@echo ""
	@echo "  make install-skill    Symlink skill/ subdirs into ~/.claude/skills/dialed:*"
	@echo "  make uninstall-skill  Remove the symlinks"
	@echo "  make test             Run the same checks CI runs locally"
	@echo ""
	@echo "  (targets implemented in later milestones)"

install-skill:
	@echo "Not yet implemented (task #117)."
	@exit 1

uninstall-skill:
	@echo "Not yet implemented (task #117)."
	@exit 1

test:
	@echo "Not yet implemented (task #117)."
	@exit 1
