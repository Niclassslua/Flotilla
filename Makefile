.PHONY: build build-release build-ephemeral test clean run run-ephemeral xcodegen

SCHEME := Flotilla
EPHEMERAL_SCHEME := Flotilla Ephemeral
PROJECT := Flotilla.xcodeproj
DERIVED_DATA := build/DerivedData
EPHEMERAL_APP := $(DERIVED_DATA)/Build/Products/Ephemeral/Flotilla Ephemeral.app

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
		-parallel-testing-enabled YES \
		-maximum-parallel-testing-workers 3 \
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

clean:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		clean
	rm -rf $(DERIVED_DATA) build
