# Notchling
#
# `make install` builds, assembles the .app, installs it to ~/Applications, wires the Claude
# Code hooks and launches it. The targets below it are the individual steps.

APP_NAME    := Notchling
BUNDLE      := $(APP_NAME).app
BUILD_DIR   := .build/release
STAGE       := .build/bundle
INSTALL_DIR := $(HOME)/Applications
INSTALLED   := $(INSTALL_DIR)/$(BUNDLE)
HOOK_PATH   := $(INSTALLED)/Contents/MacOS/notchling-hook
STATUSLINE_PATH := $(INSTALLED)/Contents/Resources/statusline-usage.sh
AGENT_PLIST := $(HOME)/Library/LaunchAgents/local.notchling.plist

# Ad-hoc signing works fine. A real identity is only worth it if you use the iTerm2/Terminal focus
# fallbacks: an ad-hoc signature's hash changes on every rebuild, so macOS re-asks for AppleEvents
# permission each time you reinstall. Takes the first Apple Development certificate found; override
# with `make install SIGN_ID=<hash>` to pick a specific one.
SIGN_ID ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $$2; exit}')
CODESIGN_ID := $(if $(SIGN_ID),$(SIGN_ID),-)

.PHONY: all build test bundle icon install install-hooks uninstall-hooks statusline no-statusline sessions uninstall run stop restart autostart no-autostart clean

all: bundle

build:
	swift build -c release

# The hook-contract tests drive the real notchling-hook binary, so build it first.
test:
	swift build --build-tests
	swift test

# Regenerate the icon from the same pixel art the widget draws, so the two cannot drift.
icon:
	python3 make-icon.py

# Assemble the .app by hand. The bundle is what carries the icon, LSUIElement and a stable identity
# for the AppleEvents permission the focus fallbacks need.
bundle: build
	rm -rf "$(STAGE)"
	mkdir -p "$(STAGE)/$(BUNDLE)/Contents/MacOS"
	mkdir -p "$(STAGE)/$(BUNDLE)/Contents/Resources"
	cp Resources/Info.plist "$(STAGE)/$(BUNDLE)/Contents/Info.plist"
	cp Resources/Notchling.icns "$(STAGE)/$(BUNDLE)/Contents/Resources/Notchling.icns"
	cp statusline-usage.sh "$(STAGE)/$(BUNDLE)/Contents/Resources/statusline-usage.sh"
	chmod +x "$(STAGE)/$(BUNDLE)/Contents/Resources/statusline-usage.sh"
	cp "$(BUILD_DIR)/$(APP_NAME)" "$(STAGE)/$(BUNDLE)/Contents/MacOS/$(APP_NAME)"
	cp "$(BUILD_DIR)/notchling-hook" "$(STAGE)/$(BUNDLE)/Contents/MacOS/notchling-hook"
	printf 'APPL????' > "$(STAGE)/$(BUNDLE)/Contents/PkgInfo"
	# Sign the extra Mach-O first, then the bundle, so the outer signature seals a stable tree.
	codesign --force --sign "$(CODESIGN_ID)" --timestamp=none "$(STAGE)/$(BUNDLE)/Contents/MacOS/notchling-hook"
	codesign --force --sign "$(CODESIGN_ID)" --timestamp=none "$(STAGE)/$(BUNDLE)"
	@echo "built $(STAGE)/$(BUNDLE) (signed with $(CODESIGN_ID))"
	@if [ "$(CODESIGN_ID)" = "-" ]; then \
	  echo "note: no Apple Development identity found, signed ad-hoc. Everything works; macOS will"; \
	  echo "      just re-ask for AppleEvents permission after each reinstall if you use the"; \
	  echo "      iTerm2/Terminal focus fallbacks."; \
	fi

install: bundle stop
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALLED)"
	cp -R "$(STAGE)/$(BUNDLE)" "$(INSTALLED)"
	# Register with LaunchServices so the bundle id resolves before first launch.
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$(INSTALLED)"
	$(MAKE) install-hooks
	open "$(INSTALLED)"
	@echo
	@echo "installed to $(INSTALLED)"
	@echo "hooks point at $(HOOK_PATH)"
	@echo "restart any running Claude sessions, or start a new one."

install-hooks:
	./install-hooks.sh install "$(HOOK_PATH)"

# Separate from `install` on purpose: registering a status line makes Claude Code drop some of its
# footer hints, which should be opted into rather than inherited. The script lives inside the bundle,
# so this setting survives reinstalls without repointing.
statusline:
	./install-hooks.sh statusline "$(STATUSLINE_PATH)"

no-statusline:
	./install-hooks.sh no-statusline ""

uninstall-hooks:
	./install-hooks.sh uninstall "$(HOOK_PATH)"

uninstall: stop uninstall-hooks no-statusline no-autostart
	rm -rf "$(INSTALLED)"
	rm -rf "$(HOME)/.notchling"
	@echo "removed $(INSTALLED), its hooks and its spool directory"

sessions:
	./list-sessions.sh

run:
	open "$(INSTALLED)"

stop:
	-@pkill -x "$(APP_NAME)" 2>/dev/null || true

restart: stop run

# Start at login and stay running.
autostart:
	mkdir -p "$(HOME)/Library/LaunchAgents"
	printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict>' \
	  '  <key>Label</key><string>local.notchling</string>' \
	  '  <key>ProgramArguments</key><array>' \
	  '    <string>$(INSTALLED)/Contents/MacOS/$(APP_NAME)</string>' \
	  '  </array>' \
	  '  <key>RunAtLoad</key><true/>' \
	  '  <key>KeepAlive</key><true/>' \
	  '  <key>ProcessType</key><string>Interactive</string>' \
	  '</dict></plist>' > "$(AGENT_PLIST)"
	-launchctl bootout "gui/$(shell id -u)/local.notchling" 2>/dev/null || true
	launchctl bootstrap "gui/$(shell id -u)" "$(AGENT_PLIST)"
	@echo "will start at login"

no-autostart:
	-@launchctl bootout "gui/$(shell id -u)/local.notchling" 2>/dev/null || true
	-@rm -f "$(AGENT_PLIST)"

clean:
	rm -rf .build
