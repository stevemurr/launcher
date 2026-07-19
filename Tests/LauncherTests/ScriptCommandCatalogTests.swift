import XCTest
@testable import Launcher

final class ScriptCommandCatalogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ name: String, _ contents: String) throws {
        try contents.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testDiscoversAnnotatedScriptsSortedByTitle() throws {
        try write("b.sh", "#!/bin/sh\n# @raycast.title Zebra\necho hi")
        try write("a.py", "#!/usr/bin/env python3\n# @launcher.title Apple\nprint('hi')")

        let scripts = ScriptCommandCatalog.discoverScripts(in: directory)

        XCTAssertEqual(scripts.map(\.title), ["Apple", "Zebra"])
    }

    func testIgnoresFilesWithoutMetadataHiddenFilesAndSubdirectories() throws {
        try write("plain.sh", "#!/bin/sh\necho no metadata")
        try write(".hidden.sh", "#!/bin/sh\n# @raycast.title Hidden\necho hi")
        let subdirectory = directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        try "#!/bin/sh\n# @raycast.title Nested\necho hi".write(
            to: subdirectory.appendingPathComponent("nested.sh"), atomically: true, encoding: .utf8)

        XCTAssertEqual(ScriptCommandCatalog.discoverScripts(in: directory), [])
    }

    func testMissingDirectoryYieldsEmpty() {
        let missing = directory.appendingPathComponent("does-not-exist", isDirectory: true)
        XCTAssertEqual(ScriptCommandCatalog.discoverScripts(in: missing), [])
    }
}

final class LauncherSettingsScriptsDirectoryTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "LauncherSettingsScriptsDirectoryTests")!
        defaults.removePersistentDomain(forName: "LauncherSettingsScriptsDirectoryTests")
    }

    func testDefaultsToHomeLauncherScripts() {
        XCTAssertEqual(LauncherSettings(defaults: defaults).scriptsDirectory, LauncherSettings.defaultScriptsDirectory)
    }

    func testSaveRoundTrips() {
        let custom = URL(fileURLWithPath: "/tmp/my-scripts", isDirectory: true)
        LauncherSettings(defaults: defaults).save(scriptsDirectory: custom)

        XCTAssertEqual(LauncherSettings(defaults: defaults).scriptsDirectory.path, custom.path)
    }
}
