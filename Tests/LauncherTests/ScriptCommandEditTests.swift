import XCTest
@testable import Launcher

final class ScriptCommandEditTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ name: String, _ contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func loadDraft(from url: URL) throws -> ScriptDraft {
        let contents = try String(contentsOf: url, encoding: .utf8)
        let command = try XCTUnwrap(ScriptMetadataParser.parse(contents: contents, url: url))
        return ScriptDraft(command: command)
    }

    func testDraftPrefillsFromCommand() throws {
        let url = try write("prefill.py", """
        #!/usr/bin/env python3
        # @raycast.title Prefilled
        # @raycast.mode inline
        # @raycast.packageName Utils
        # @raycast.description Does things
        # @raycast.needsConfirmation true
        # @raycast.argument1 { "type": "text", "placeholder": "Input" }
        print("x")
        """)

        let draft = try loadDraft(from: url)

        XCTAssertEqual(draft.template, .python)
        XCTAssertEqual(draft.title, "Prefilled")
        XCTAssertEqual(draft.mode, .normal)
        XCTAssertEqual(draft.packageName, "Utils")
        XCTAssertEqual(draft.description, "Does things")
        XCTAssertTrue(draft.needsConfirmation)
        XCTAssertEqual(draft.argumentPlaceholders, ["Input"])
    }

    func testUpdatePreservesBodyShebangAndUnmanagedLines() throws {
        let url = try write("keep.sh", """
        #!/bin/zsh
        # @raycast.schemaVersion 1
        # @raycast.title Keeper
        # @raycast.mode compact

        # regular comment stays
        echo "line one"
        echo "line two"
        """)

        var draft = try loadDraft(from: url)
        draft.title = "Keeper Renamed"
        try ScriptCommandCreator.update(draft: draft, at: url)

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.hasPrefix("#!/bin/zsh\n"))
        XCTAssertTrue(contents.contains("# @raycast.schemaVersion 1"))
        XCTAssertTrue(contents.contains("# @raycast.title Keeper Renamed"))
        XCTAssertTrue(contents.contains("# regular comment stays"))
        XCTAssertTrue(contents.contains("echo \"line one\"\necho \"line two\""))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path))
    }

    func testUpdateLeavesUnchangedFileIdentical() throws {
        let original = """
        #!/bin/bash
        # @raycast.title Same
        # @raycast.mode silent
        # @raycast.packageName Ops
        # @raycast.argument1 { "type": "text", "placeholder": "Host", "optional": true }
        echo hi
        """
        let url = try write("same.sh", original)

        try ScriptCommandCreator.update(draft: loadDraft(from: url), at: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
    }

    /// fullOutput/compact/inline all mean `.normal`, so editing an unrelated
    /// field must not rewrite the author's chosen spelling.
    func testUpdateKeepsLegacyModeSpelling() throws {
        for legacy in ["fullOutput", "compact", "inline"] {
            let url = try write("legacy-\(legacy).sh", """
            #!/bin/bash
            # @raycast.title Legacy
            # @raycast.mode \(legacy)
            echo hi
            """)

            var draft = try loadDraft(from: url)
            XCTAssertEqual(draft.mode, .normal)
            draft.title = "Legacy Renamed"
            try ScriptCommandCreator.update(draft: draft, at: url)

            let contents = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(
                contents.contains("# @raycast.mode \(legacy)"),
                "\(legacy) should survive an unrelated edit untouched"
            )
            XCTAssertTrue(contents.contains("# @raycast.title Legacy Renamed"))
        }
    }

    func testUpdateStillRewritesModeWhenItActuallyChanges() throws {
        let url = try write("switch.sh", """
        #!/bin/bash
        # @raycast.title Switcher
        # @raycast.mode inline
        echo hi
        """)

        var draft = try loadDraft(from: url)
        draft.mode = .silent
        try ScriptCommandCreator.update(draft: draft, at: url)

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("# @raycast.mode silent"))
        XCTAssertFalse(contents.contains("inline"))
    }

    func testUpdateRemovesClearedOptionalFields() throws {
        let url = try write("clear.sh", """
        #!/bin/bash
        # @raycast.title Clearer
        # @raycast.mode compact
        # @raycast.packageName Gone
        # @raycast.description Also gone
        # @raycast.needsConfirmation true
        # @raycast.argument1 { "placeholder": "Drop me" }
        echo hi
        """)

        var draft = try loadDraft(from: url)
        draft.packageName = ""
        draft.description = " "
        draft.needsConfirmation = false
        draft.argumentPlaceholders = []
        try ScriptCommandCreator.update(draft: draft, at: url)

        let contents = try String(contentsOf: url, encoding: .utf8)
        let parsed = try XCTUnwrap(ScriptMetadataParser.parse(contents: contents, url: url))
        XCTAssertNil(parsed.packageName)
        XCTAssertNil(parsed.description)
        XCTAssertFalse(parsed.needsConfirmation)
        XCTAssertTrue(parsed.arguments.isEmpty)
        XCTAssertFalse(contents.contains("Drop me"))
    }

    func testUpdateAddsNewFieldsAfterExistingMetadata() throws {
        let url = try write("grow.sh", """
        #!/bin/bash
        # @raycast.title Grower
        echo hi
        """)

        var draft = try loadDraft(from: url)
        draft.description = "Now documented"
        draft.needsConfirmation = true
        draft.argumentPlaceholders = ["City", ""]
        try ScriptCommandCreator.update(draft: draft, at: url)

        let contents = try String(contentsOf: url, encoding: .utf8)
        let parsed = try XCTUnwrap(ScriptMetadataParser.parse(contents: contents, url: url))
        XCTAssertEqual(parsed.description, "Now documented")
        XCTAssertTrue(parsed.needsConfirmation)
        XCTAssertEqual(parsed.arguments.map(\.placeholder), ["City", "Argument 2"])
        // New lines land in the header, not after the body.
        let bodyIndex = try XCTUnwrap(contents.range(of: "echo hi")).lowerBound
        let descriptionIndex = try XCTUnwrap(contents.range(of: "Now documented")).lowerBound
        XCTAssertLessThan(descriptionIndex, bodyIndex)
    }

    func testUpdateMergesArgumentJSONPreservingExtraFields() throws {
        let url = try write("merge.sh", """
        #!/bin/bash
        # @raycast.title Merger
        # @raycast.argument1 { "type": "text", "placeholder": "Old", "optional": true }
        echo hi
        """)

        var draft = try loadDraft(from: url)
        draft.argumentPlaceholders = ["New"]
        try ScriptCommandCreator.update(draft: draft, at: url)

        let contents = try String(contentsOf: url, encoding: .utf8)
        let parsed = try XCTUnwrap(ScriptMetadataParser.parse(contents: contents, url: url))
        XCTAssertEqual(parsed.arguments.first?.placeholder, "New")
        XCTAssertEqual(parsed.arguments.first?.optional, true, "optional flag must survive a placeholder edit")
    }

    func testUpdateDropsDuplicateManagedLines() throws {
        let url = try write("dupe.sh", """
        #!/bin/bash
        # @raycast.title First Wins
        # @launcher.title Stale Duplicate
        echo hi
        """)

        var draft = try loadDraft(from: url)
        draft.title = "Only One"
        try ScriptCommandCreator.update(draft: draft, at: url)

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("Only One"))
        XCTAssertFalse(contents.contains("Stale Duplicate"))
        XCTAssertFalse(contents.contains("First Wins"))
    }

    func testUpdateIgnoresMetadataLookalikesBelowHeaderWindow() throws {
        let filler = Array(repeating: "# padding", count: 50).joined(separator: "\n")
        let url = try write("deep.sh", """
        #!/bin/bash
        # @raycast.title Deep
        \(filler)
        cat <<'EOF'
        # @raycast.title Not Metadata
        EOF
        """)

        var draft = try loadDraft(from: url)
        draft.title = "Deep Renamed"
        try ScriptCommandCreator.update(draft: draft, at: url)

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("# @raycast.title Deep Renamed"))
        XCTAssertTrue(contents.contains("# @raycast.title Not Metadata"), "body heredoc must not be rewritten")
    }

    func testUpdateNeverRemovesTitle() throws {
        let url = try write("titled.sh", """
        #!/bin/bash
        # @raycast.title Sticky Title
        echo hi
        """)

        var draft = try loadDraft(from: url)
        draft.title = "   "
        try ScriptCommandCreator.update(draft: draft, at: url)

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("# @raycast.title Sticky Title"))
    }
}
