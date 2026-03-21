PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin

.PHONY: install install-user uninstall uninstall-user test release

install:
	install -m 755 claude-at.sh $(BINDIR)/claude-at
	ln -sf $(BINDIR)/claude-at $(BINDIR)/ca

install-user:
	mkdir -p $(HOME)/.local/bin
	install -m 755 claude-at.sh $(HOME)/.local/bin/claude-at
	ln -sf $(HOME)/.local/bin/claude-at $(HOME)/.local/bin/ca
	@echo "Ensure ~/.local/bin is in your PATH"

uninstall:
	@if ls $(HOME)/Library/LaunchAgents/com.claude-at.*.plist 1>/dev/null 2>&1; then \
		echo "Warning: active claude-at jobs detected. Run 'ca -c all' first, then cancel recurring jobs individually."; \
	fi
	rm -f $(BINDIR)/claude-at $(BINDIR)/ca

uninstall-user:
	@if ls $(HOME)/Library/LaunchAgents/com.claude-at.*.plist 1>/dev/null 2>&1; then \
		echo "Warning: active claude-at jobs detected. Run 'ca -c all' first, then cancel recurring jobs individually."; \
	fi
	rm -f $(HOME)/.local/bin/claude-at $(HOME)/.local/bin/ca

test:
	@echo "Running smoke tests..."
	@bash claude-at.sh version | grep -q "claude-at" && echo "  PASS: version" || echo "  FAIL: version"
	@bash claude-at.sh --version | grep -q "claude-at" && echo "  PASS: --version (compat)" || echo "  FAIL: --version (compat)"
	@bash claude-at.sh help >/dev/null 2>&1 && echo "  PASS: help" || echo "  FAIL: help"
	@bash claude-at.sh --help >/dev/null 2>&1 && echo "  PASS: --help (compat)" || echo "  FAIL: --help (compat)"
	@echo "Done."

release:
	@[ -n "$(V)" ] || { echo "Usage: make release V=x.y.z"; exit 1; }
	@echo "Releasing v$(V)..."
	@sed -i '' 's/^VERSION="[^"]*"/VERSION="$(V)"/' claude-at.sh
	@git add claude-at.sh
	@git commit -m "chore: bump version to $(V)"
	@git tag "v$(V)"
	@git push origin main --tags
	@echo "Done. GitHub Actions will create the release and update Homebrew."
