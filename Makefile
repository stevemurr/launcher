.PHONY: project build run test compile-ui-tests ui-test clean

project:
	xcodegen generate

build: project
	xcodebuild -project Launcher.xcodeproj -scheme Launcher -derivedDataPath .xcode-build build

run: build
	open .xcode-build/Build/Products/Debug/Launcher.app

test:
	swift test

compile-ui-tests: project
	xcodebuild -project Launcher.xcodeproj -scheme LauncherUITests -derivedDataPath .xcode-build build-for-testing

ui-test: project
	./Scripts/run-ui-tests.sh

clean:
	swift package clean
	xcodebuild -project Launcher.xcodeproj -scheme Launcher clean
