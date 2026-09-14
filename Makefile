.PHONY: build build-release build-ephemeral build-companion test test-companion clean run run-ephemeral run-board-demo run-companion run-companion-demo xcodegen

SCHEME := Flotilla
EPHEMERAL_SCHEME := Flotilla Ephemeral
PROJECT := Flotilla.xcodeproj
DERIVED_DATA := build/DerivedData
EPHEMERAL_APP := $(DERIVED_DATA)/Build/Products/Ephemeral/Flotilla Ephemeral.app
COMPANION_SCHEME := FlotillaCompanion
COMPANION_APP := $(DERIVED_DATA)/Build/Products/Debug-iphonesimulator/FlotillaCompanion.app
COMPANION_BUNDLE_ID := com.niclassslua.flotilla.companion
# Any installed iPhone simulator name; override with `make run-companion SIMULATOR="iPhone 17"`.
LPAREN := (
SIMULATOR ?= $(shell xcrun simctl list devices available | grep -m1 iPhone | sed -E 's/^ +//; s/ [$(LPAREN)].*//')
# Boots the demo straight into a scripted state, e.g. `make run-companion-demo SCENARIO=stackedPermissions`.
SCENARIO ?=

xcodegen:
	xcodegen generate

build: xcodegen
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Debug \
		-destination 'platform=macOS' \
		-derivedDataPath $(DERIVED_DATA) \
		build

build-release: xcodegen
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Release \
		-destination 'platform=macOS' \
		-derivedDataPath $(DERIVED_DATA) \
		build

build-ephemeral: xcodegen
	xcodebuild \
		-project $(PROJECT) \
		-scheme "$(EPHEMERAL_SCHEME)" \
		-configuration Ephemeral \
		-destination 'platform=macOS' \
		-derivedDataPath $(DERIVED_DATA) \
		build

build-companion: xcodegen
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(COMPANION_SCHEME) \
		-configuration Debug \
		-destination 'generic/platform=iOS Simulator' \
		-derivedDataPath $(DERIVED_DATA) \
		build

test: xcodegen
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Debug \
		-destination 'platform=macOS' \
		-derivedDataPath $(DERIVED_DATA) \
		-parallel-testing-enabled YES \
		-maximum-parallel-testing-workers 4 \
		test -only-testing:FlotillaUnitTests

test-ui: xcodegen
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Debug \
		-destination 'platform=macOS' \
		-derivedDataPath $(DERIVED_DATA) \
		-parallel-testing-enabled NO \
		test -only-testing:FlotillaUITests

archive: xcodegen
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Release \
		-destination 'generic/platform=macOS' \
		-derivedDataPath $(DERIVED_DATA) \
		-archivePath build/Flotilla.xcarchive \
		archive

run: build
	open $(DERIVED_DATA)/Build/Products/Debug/Flotilla.app

run-ephemeral: build-ephemeral
	open "$(EPHEMERAL_APP)"

# Ephemeral app on a throwaway in-memory database seeded with a fleet that
# covers every session status, waiting reason, and agent. Launched through
# the binary rather than `open` because `open` does not forward environment
# variables. Never touches the real session store.
run-board-demo: build-ephemeral
	FLOTILLA_DEMO_DATA=1 "$(EPHEMERAL_APP)/Contents/MacOS/Flotilla Ephemeral" &

# iOS companion in the simulator, connecting to real Macs.
run-companion: build-companion
	xcrun simctl boot "$(SIMULATOR)" 2>/dev/null || true
	open -b com.apple.iphonesimulator 2>/dev/null || true
	xcrun simctl install "$(SIMULATOR)" "$(COMPANION_APP)"
	xcrun simctl launch --terminate-running-process "$(SIMULATOR)" $(COMPANION_BUNDLE_ID)

# The companion on its fixture fleet and scripted scenarios — no Mac needed.
run-companion-demo: build-companion
	xcrun simctl boot "$(SIMULATOR)" 2>/dev/null || true
	open -b com.apple.iphonesimulator 2>/dev/null || true
	xcrun simctl install "$(SIMULATOR)" "$(COMPANION_APP)"
	xcrun simctl launch --terminate-running-process "$(SIMULATOR)" $(COMPANION_BUNDLE_ID) -demo $(if $(SCENARIO),-scenario $(SCENARIO))

# Simulator processes can't read ~/Documents, where build/ usually lives, so the
# test host would hang loading XCTest from there. Build tests outside it.
COMPANION_TEST_DERIVED_DATA := $(HOME)/Library/Developer/Xcode/DerivedData/FlotillaCompanionTests

test-companion: xcodegen
	cd Packages/CompanionKit && swift test
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(COMPANION_SCHEME) \
		-destination 'platform=iOS Simulator,name=$(SIMULATOR)' \
		-derivedDataPath "$(COMPANION_TEST_DERIVED_DATA)" \
		-test-timeouts-enabled YES \
		test

clean:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		clean
	rm -rf $(DERIVED_DATA) build
