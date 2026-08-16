.PHONY: build build-release test clean run xcodegen

SCHEME := Flotilla
PROJECT := Flotilla.xcodeproj
DERIVED_DATA := build/DerivedData

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

test: xcodegen
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Debug \
		-destination 'platform=macOS' \
		-derivedDataPath $(DERIVED_DATA) \
		test -only-testing:FlotillaUnitTests

test-ui: xcodegen
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Debug \
		-destination 'platform=macOS' \
		-derivedDataPath $(DERIVED_DATA) \
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

clean:
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		clean
	rm -rf $(DERIVED_DATA) build
