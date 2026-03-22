PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin

.PHONY: install install-user uninstall uninstall-user test release

install:
	install -m 755 claude-brb.sh $(BINDIR)/claude-brb
	ln -sf $(BINDIR)/claude-brb $(BINDIR)/brb

install-user:
	mkdir -p $(HOME)/.local/bin
	install -m 755 claude-brb.sh $(HOME)/.local/bin/claude-brb
	ln -sf $(HOME)/.local/bin/claude-brb $(HOME)/.local/bin/brb
	@echo "Ensure ~/.local/bin is in your PATH"

uninstall:
	@if ls $(HOME)/Library/LaunchAgents/com.claude-brb.*.plist 1>/dev/null 2>&1; then \
		echo "Warning: active claude-brb jobs detected. Run 'brb teardown' or 'brb cancel all' first."; \
	fi
	rm -f $(BINDIR)/claude-brb $(BINDIR)/brb

uninstall-user:
	@if ls $(HOME)/Library/LaunchAgents/com.claude-brb.*.plist 1>/dev/null 2>&1; then \
		echo "Warning: active claude-brb jobs detected. Run 'brb teardown' or 'brb cancel all' first."; \
	fi
	rm -f $(HOME)/.local/bin/claude-brb $(HOME)/.local/bin/brb

test:
	bash test-v2.sh

release:
	@[ -n "$(V)" ] || { echo "Usage: make release V=x.y.z"; exit 1; }
	@echo "Releasing v$(V)..."
	@sed -i '' 's/^VERSION="[^"]*"/VERSION="$(V)"/' claude-brb.sh
	@git add claude-brb.sh
	@git commit -m "chore: bump version to $(V)"
	@git tag "v$(V)"
	@git push origin main --tags
	@echo "Done. GitHub Actions will create the release and update Homebrew."
