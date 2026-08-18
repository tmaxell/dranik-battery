SWIFT      ?= swift
CC         ?= clang
CONFIG     ?= release
BUILD_DIR  := .build/$(CONFIG)
TOOLS_DIR  := .build/tools
FRAMEWORKS := -framework IOKit -framework CoreFoundation
APP_BUNDLE := $(BUILD_DIR)/Dranik.app
# One source of truth for the version: the constant both halves report.
APP_VERSION := $(shell sed -n 's/.*current = "\(.*\)".*/\1/p' Sources/DranikCore/Version.swift)
AGENT_PLIST := $(HOME)/Library/LaunchAgents/com.dranik.battery.app.plist

.PHONY: all build test run status dump probe tools clean help install uninstall daemon-dry-run logs gate-dry-run gate-experiment app app-run install-app uninstall-app ui-drill

all: build

## build: compile the package
##
## Refuses to run as root. `make install` elevates only the install script, so
## running the whole target under sudo would build as root and leave .build
## owned by root — after which an ordinary `make test` cannot write to it.
build:
	@if [ "$$(id -u)" = "0" ]; then \
		echo "do not build as root: run 'make install', not 'sudo make install'." >&2; \
		echo "if .build is already root-owned: sudo chown -R \"$$SUDO_USER\" .build" >&2; \
		exit 1; \
	fi
	$(SWIFT) build -c $(CONFIG)

## test: run the self-test suite
##
## Not `swift test`: XCTest lives in Xcode, and `xcode-select` points at Command
## Line Tools, so it cannot be imported. The suite is an ordinary executable
## instead. Exits non-zero on failure. Reads only — writes nothing to the SMC.
test:
	$(SWIFT) run -c $(CONFIG) dranik-selftest

## install: install dranikd as a LaunchDaemon. Run as yourself, NOT with sudo —
##          it elevates the install script on its own.
install: build
	sudo ./scripts/install.sh

## uninstall: stop it, confirm the gate is open, then remove it (needs root)
uninstall:
	sudo ./scripts/uninstall.sh

## app: assemble the menu bar app bundle in .build/
##
## No Xcode: SwiftUI is in the Command Line Tools SDK, and an app bundle is a
## directory with an Info.plist and a binary in it. Signed ad-hoc, which is all a
## locally built and locally run app needs — the daemon already did the
## privileged part, so the app needs no entitlements and no Developer ID.
app: build
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@cp "$(BUILD_DIR)/DranikApp" "$(APP_BUNDLE)/Contents/MacOS/Dranik"
	@sed 's/__VERSION__/$(APP_VERSION)/g' scripts/Info.plist > "$(APP_BUNDLE)/Contents/Info.plist"
	@codesign --force --sign - "$(APP_BUNDLE)"
	@echo "built $(APP_BUNDLE) (version $(APP_VERSION))"

## app-run: build the app and launch it from .build, without installing
app-run: app
	@pkill -f "Dranik.app/Contents/MacOS/Dranik" 2>/dev/null || true
	open "$(APP_BUNDLE)"

## install-app: put the app in /Applications and start it at login
##
## Needs no root: it is an ordinary user application talking to a socket the
## daemon already opened to the admin group.
install-app: app
	@pkill -f "Dranik.app/Contents/MacOS/Dranik" 2>/dev/null || true
	rm -rf /Applications/Dranik.app
	cp -R "$(APP_BUNDLE)" /Applications/Dranik.app
	@mkdir -p "$(HOME)/Library/LaunchAgents"
	cp scripts/com.dranik.battery.app.plist "$(AGENT_PLIST)"
	@launchctl bootout gui/$$(id -u)/com.dranik.battery.app 2>/dev/null || true
	launchctl bootstrap gui/$$(id -u) "$(AGENT_PLIST)"
	@echo "installed — the battery icon is in the menu bar"

## uninstall-app: remove the app and stop it starting at login
##
## Leaves the daemon alone: the limit goes on being enforced without the GUI,
## which is the point of the GUI not being where the logic lives.
uninstall-app:
	@launchctl bootout gui/$$(id -u)/com.dranik.battery.app 2>/dev/null || true
	rm -f "$(AGENT_PLIST)"
	@pkill -f "Dranik.app/Contents/MacOS/Dranik" 2>/dev/null || true
	rm -rf /Applications/Dranik.app
	@echo "removed — the daemon is untouched"

## daemon-dry-run: watch the daemon decide. It NEVER writes to the SMC, so the
##                  battery WILL charge past the limit. Needs no root. Ctrl-C to stop,
##                  then `sudo make install` to have it actually act.
daemon-dry-run: build
	$(BUILD_DIR)/dranikd --dry-run --config /tmp/dranik-dry.json \
		--state /tmp/dranik-dry-state.json --lock /tmp/dranik-dry.pid

## logs: follow what the daemon is doing
logs:
	sudo /usr/bin/log stream --predicate 'subsystem == "com.dranik.battery"' --level debug

## gate-dry-run: rehearse the charge-gate experiment, writing nothing
gate-dry-run: build
	$(BUILD_DIR)/dranik-gate-experiment --dry-run

## gate-experiment: verify the charge gate for real — WRITES TO THE SMC, needs root
##
## Stops charging for up to 30 seconds, then reopens the gate unconditionally.
## The rollback is armed before the first write. Run it plugged in and charging.
gate-experiment: build
	sudo $(BUILD_DIR)/dranik-gate-experiment

## status: show battery state and charge-control capabilities
status: build
	$(BUILD_DIR)/dranik status

## dump: enumerate every SMC key as TSV
dump: build
	$(BUILD_DIR)/dranik smc --dump

## tools: build the standalone C probes
tools: $(TOOLS_DIR)/smcprobe $(TOOLS_DIR)/smcdump

$(TOOLS_DIR)/smcprobe: tools/smcprobe.c
	@mkdir -p $(TOOLS_DIR)
	$(CC) -O2 -Wall -o $@ $< $(FRAMEWORKS)

$(TOOLS_DIR)/smcdump: tools/smcdump.c
	@mkdir -p $(TOOLS_DIR)
	$(CC) -O2 -Wall -o $@ $< $(FRAMEWORKS)

## probe: run the standalone C probe (reference implementation, read-only)
probe: $(TOOLS_DIR)/smcprobe
	$(TOOLS_DIR)/smcprobe

clean:
	rm -rf .build

help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## //'

## ui-drill: run the menu bar app against a daemon that misbehaves on purpose
##
## Reads nothing real and writes nothing: a temporary socket, canned reports, and
## the app's own `--check` output read back. Needs no root and no daemon.
ui-drill: app
	$(BUILD_DIR)/dranik-ui-drill
