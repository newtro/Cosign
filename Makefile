# Cosign: build, test, run, and install from the command line.
# The Xcode project is generated from project.yml (XcodeGen) and not committed.
#
# Debug builds are "Cosign Dev" (bundle id com.scottsmith.cosign.debug, data in
# ~/Library/Application Support/Cosign Dev). Release is the installed "Cosign"
# (/Applications/Cosign.app, com.scottsmith.cosign).

PROJECT := Cosign.xcodeproj
DERIVED := build
XCODEBUILD := xcodebuild -project $(PROJECT) -scheme Cosign -configuration Debug -derivedDataPath $(DERIVED)
XCODEBUILD_RELEASE := xcodebuild -project $(PROJECT) -scheme Cosign -configuration Release -derivedDataPath $(DERIVED)
APP := $(DERIVED)/Build/Products/Debug/Cosign.app
RELEASE_APP := $(DERIVED)/Build/Products/Release/Cosign.app
INSTALLED := /Applications/Cosign.app

.PHONY: build test test-package test-app run release install icons project clean

build: project
	$(XCODEBUILD) build

test: test-package test-app

test-package:
	cd Packages/CosignCore && swift test
	cd Packages/CosignVoice && swift test

test-app: project
	$(XCODEBUILD) test

run: build
	open '$(APP)'

release: project
	$(XCODEBUILD_RELEASE) build

install: release
	@if pgrep -f '^$(INSTALLED)/Contents/MacOS/Cosign' >/dev/null; then \
		echo "Cosign is running. Quit it first, then run make install again."; exit 1; fi
	rm -rf '$(INSTALLED).installing'
	ditto '$(RELEASE_APP)' '$(INSTALLED).installing'
	rm -rf '$(INSTALLED)'
	mv '$(INSTALLED).installing' '$(INSTALLED)'
	touch '$(INSTALLED)'
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f '$(INSTALLED)'
	@echo "Installed $(INSTALLED)"

icons:
	swift Tools/make-icon.swift App/Assets.xcassets

project: $(PROJECT)

$(PROJECT): project.yml App AppTests
	xcodegen generate
	@touch $(PROJECT)

clean:
	rm -rf $(DERIVED) $(PROJECT) Packages/CosignCore/.build Packages/CosignVoice/.build
