SWIFT      ?= swift
CC         ?= clang
CONFIG     ?= release
BUILD_DIR  := .build/$(CONFIG)
TOOLS_DIR  := .build/tools
FRAMEWORKS := -framework IOKit -framework CoreFoundation

.PHONY: all build test run status dump probe tools clean help

all: build

## build: compile the package
build:
	$(SWIFT) build -c $(CONFIG)

## test: run the self-test suite
##
## Not `swift test`: XCTest lives in Xcode, and `xcode-select` points at Command
## Line Tools, so it cannot be imported. The suite is an ordinary executable
## instead. Exits non-zero on failure. Reads only — writes nothing to the SMC.
test:
	$(SWIFT) run -c $(CONFIG) dranik-selftest

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
