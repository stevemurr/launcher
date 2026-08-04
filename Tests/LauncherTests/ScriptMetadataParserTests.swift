import XCTest
@testable import Launcher

final class ScriptMetadataParserTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/scripts/example.sh")

    private func parse(_ contents: String) -> ScriptCommand? {
        ScriptMetadataParser.parse(contents: contents, url: url)
    }

    func testFullRaycastHeader() {
        let script = parse("""
        #!/bin/bash
        # @raycast.schemaVersion 1
        # @raycast.title Youtube Download Audio
        # @raycast.mode compact
        # @raycast.packageName Media
        # @raycast.description Download audio from a YouTube URL
        # @raycast.needsConfirmation true
        # @raycast.argument1 { "type": "text", "placeholder": "URL" }
        echo hi
        """)

        XCTAssertEqual(script?.title, "Youtube Download Audio")
        XCTAssertEqual(script?.mode, .normal)
        XCTAssertEqual(script?.packageName, "Media")
        XCTAssertEqual(script?.description, "Download audio from a YouTube URL")
        XCTAssertEqual(script?.needsConfirmation, true)
        XCTAssertEqual(script?.arguments, [ScriptArgument(placeholder: "URL", optional: false)])
        XCTAssertEqual(script?.id, url.path)
    }

    func testLauncherPrefixAndMixedPrefixes() {
        let script = parse("""
        #!/bin/zsh
        # @launcher.title Mixed
        # @raycast.mode inline
        # @launcher.packageName Tools
        """)

        XCTAssertEqual(script?.title, "Mixed")
        XCTAssertEqual(script?.mode, .normal)
        XCTAssertEqual(script?.packageName, "Tools")
    }

    func testSlashSlashComments() {
        let script = parse("""
        #!/usr/bin/env node
        // @raycast.title Node Script
        // @raycast.mode silent
        """)

        XCTAssertEqual(script?.title, "Node Script")
        XCTAssertEqual(script?.mode, .silent)
    }

    func testMissingTitleReturnsNil() {
        XCTAssertNil(parse("#!/bin/bash\n# @raycast.mode compact\necho hi"))
        XCTAssertNil(parse("#!/bin/bash\necho plain script"))
        XCTAssertNil(parse(""))
    }

    func testDefaults() {
        let script = parse("# @raycast.title Bare")
        XCTAssertEqual(script?.mode, .normal)
        XCTAssertNil(script?.packageName)
        XCTAssertNil(script?.description)
        XCTAssertEqual(script?.needsConfirmation, false)
        XCTAssertEqual(script?.arguments, [])
    }

    func testUnknownModeFallsBackToNormal() {
        XCTAssertEqual(parse("# @raycast.title X\n# @raycast.mode bogus")?.mode, .normal)
    }

    func testLegacyModeAliasesCollapseToNormal() {
        for legacy in ["fullOutput", "compact", "inline"] {
            XCTAssertEqual(
                parse("# @raycast.title X\n# @raycast.mode \(legacy)")?.mode,
                .normal,
                "\(legacy) should still parse as a normal script"
            )
        }
    }

    func testSilentModeIsCaseInsensitive() {
        for spelling in ["silent", "Silent", "SILENT"] {
            XCTAssertEqual(
                parse("# @raycast.title X\n# @raycast.mode \(spelling)")?.mode,
                .silent,
                "\(spelling) should parse as silent"
            )
        }
    }

    func testNeedsConfirmationVariants() {
        XCTAssertEqual(parse("# @raycast.title X\n# @raycast.needsConfirmation 1")?.needsConfirmation, true)
        XCTAssertEqual(parse("# @raycast.title X\n# @raycast.needsConfirmation false")?.needsConfirmation, false)
    }

    func testThreeArgumentsWithOptional() {
        let script = parse("""
        # @raycast.title Args
        # @raycast.argument1 { "type": "text", "placeholder": "First" }
        # @raycast.argument2 { "type": "text", "placeholder": "Second", "optional": true }
        # @raycast.argument3 { "type": "text", "placeholder": "Third" }
        """)

        XCTAssertEqual(script?.arguments, [
            ScriptArgument(placeholder: "First", optional: false),
            ScriptArgument(placeholder: "Second", optional: true),
            ScriptArgument(placeholder: "Third", optional: false)
        ])
    }

    func testMalformedArgumentJSONFallsBackToPlaceholder() {
        let script = parse("""
        # @raycast.title Args
        # @raycast.argument1 not-json-at-all
        """)

        XCTAssertEqual(script?.arguments, [ScriptArgument(placeholder: "Argument 1", optional: false)])
    }

    func testArgumentGapStillYieldsBothArguments() {
        let script = parse("""
        # @raycast.title Args
        # @raycast.argument1 { "placeholder": "One" }
        # @raycast.argument3 { "placeholder": "Three" }
        """)

        XCTAssertEqual(script?.arguments.map(\.placeholder), ["One", "Three"])
    }

    func testFirstOccurrenceOfKeyWins() {
        let script = parse("""
        # @raycast.title First Title
        # @launcher.title Second Title
        """)

        XCTAssertEqual(script?.title, "First Title")
    }

    func testMetadataBelowLineFiftyIsIgnored() {
        let filler = Array(repeating: "# filler", count: 55).joined(separator: "\n")
        XCTAssertNil(parse(filler + "\n# @raycast.title Too Late"))
    }
}
