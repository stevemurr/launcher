import XCTest
@testable import Launcher

final class ScriptTemplateTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("template-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testBashContentsParseBackIntoEquivalentCommand() {
        var draft = ScriptDraft()
        draft.title = "Deploy Site"
        draft.mode = .inline
        draft.description = "Ship it"
        draft.packageName = "Ops"
        draft.needsConfirmation = true
        draft.argumentPlaceholders = ["Branch", ""]

        let contents = draft.fileContents()
        XCTAssertTrue(contents.hasPrefix("#!/bin/bash\n"))

        let parsed = ScriptMetadataParser.parse(contents: contents, url: URL(fileURLWithPath: "/tmp/x.sh"))
        XCTAssertEqual(parsed?.title, "Deploy Site")
        XCTAssertEqual(parsed?.mode, .inline)
        XCTAssertEqual(parsed?.description, "Ship it")
        XCTAssertEqual(parsed?.packageName, "Ops")
        XCTAssertEqual(parsed?.needsConfirmation, true)
        XCTAssertEqual(parsed?.arguments.map(\.placeholder), ["Branch", "Argument 2"])
    }

    func testPythonTemplateUsesPythonShebangAndExtension() {
        var draft = ScriptDraft()
        draft.template = .python
        draft.title = "Hello"

        XCTAssertTrue(draft.fileContents().hasPrefix("#!/usr/bin/env python3\n"))
        XCTAssertTrue(draft.fileContents().contains("print("))
        XCTAssertEqual(draft.template.fileExtension, "py")
    }

    func testCreateWritesExecutableFileAndCreatesDirectory() throws {
        var draft = ScriptDraft()
        draft.title = "Hello World!"

        let url = try ScriptCommandCreator.create(draft: draft, in: directory)

        XCTAssertEqual(url.lastPathComponent, "hello-world.sh")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.int16Value ?? 0
        XCTAssertNotEqual(permissions & 0o111, 0, "script should be executable")
    }

    func testCreateUniquesSlugs() throws {
        var draft = ScriptDraft()
        draft.title = "Hello"

        let first = try ScriptCommandCreator.create(draft: draft, in: directory)
        let second = try ScriptCommandCreator.create(draft: draft, in: directory)

        XCTAssertEqual(first.lastPathComponent, "hello.sh")
        XCTAssertEqual(second.lastPathComponent, "hello-2.sh")
    }

    func testEmptyTitleSlugFallsBack() throws {
        var draft = ScriptDraft()
        draft.title = "!!!"

        let url = try ScriptCommandCreator.create(draft: draft, in: directory)
        XCTAssertEqual(url.lastPathComponent, "script.sh")
    }
}
