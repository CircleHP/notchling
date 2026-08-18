# Notchling
#
# `make install` builds, assembles the .app, installs it to ~/Applications, wires the Claude
# Code hooks and launches it. The targets below it are the individual steps.

APP_NAME    := Notchling
BUNDLE      := $(APP_NAME).app
STAGE       := .build/bundle
DIST_DIR    := .build/dist
INSTALL_DIR := $(HOME)/Applications
INSTALLED   := $(INSTALL_DIR)/$(BUNDLE)
HOOK_PATH   := $(INSTALLED)/Contents/MacOS/notchling-hook
STATUSLINE_PATH := $(INSTALLED)/Contents/Resources/statusline-usage.sh
AGENT_PLIST := $(HOME)/Library/LaunchAgents/local.notchling.plist

# A local build is native and fast; a distribution build is universal, so a Mac that downloads the
# binary rather than compiling it can run it whatever its architecture. Set by `dist`, not by hand.
# --arch also moves the output: .build/release stays the native symlink, universal builds land under
# .build/apple, and a BUILD_DIR that does not follow would silently ship a single-architecture app.
UNIVERSAL   :=
SWIFT_ARCHS := $(if $(UNIVERSAL),--arch arm64 --arch x86_64)
BUILD_DIR   := $(if $(UNIVERSAL),.build/apple/Products/Release,.build/release)

VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
TARBALL := notchling-$(VERSION)-universal.tar.gz

# Ad-hoc signing works fine. A real identity is only worth it if you use the iTerm2/Terminal focus
# fallbacks: an ad-hoc signature's hash changes on every rebuild, so macOS re-asks for AppleEvents
# permission each time you reinstall. Takes the first Apple Development certificate found; override
# with `make install SIGN_ID=<hash>` to pick a specific one.
SIGN_ID ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $$2; exit}')
CODESIGN_ID := $(if $(SIGN_ID),$(SIGN_ID),-)

.PHONY: all build test bundle dist icon install install-hooks uninstall-hooks statusline no-statusline sessions uninstall run stop restart autostart no-autostart clean

all: bundle

build:
	swift build -c release $(SWIFT_ARCHS)

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
	cp install-hooks.sh "$(STAGE)/$(BUNDLE)/Contents/Resources/install-hooks.sh"
	chmod +x "$(STAGE)/$(BUNDLE)/Contents/Resources/statusline-usage.sh"
	chmod +x "$(STAGE)/$(BUNDLE)/Contents/Resources/install-hooks.sh"
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

# The release tarball a Homebrew formula downloads, with its checksum beside it. Compute the formula's
# sha256 from this file on every release: a stale one looks exactly like a compromised download.
dist:
	$(MAKE) bundle UNIVERSAL=1
	mkdir -p "$(DIST_DIR)"
	rm -f "$(DIST_DIR)/$(TARBALL)" "$(DIST_DIR)/$(TARBALL).sha256"
	# Signatures live inside the Mach-O files and in Contents/_CodeSignature, both ordinary file
	# content, so tar carries them intact. --no-mac-metadata keeps out the AppleDouble entries that
	# would otherwise vary between machines for no benefit.
	tar --no-mac-metadata -C "$(STAGE)" -czf "$(DIST_DIR)/$(TARBALL)" "$(BUNDLE)"
	cd "$(DIST_DIR)" && shasum -a 256 "$(TARBALL)" > "$(TARBALL).sha256"
	./verify-dist.sh "$(STAGE)/$(BUNDLE)" "$(DIST_DIR)/$(TARBALL)"
	@echo
	@cat "$(DIST_DIR)/$(TARBALL).sha256"

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
