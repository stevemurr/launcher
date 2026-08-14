import XCTest
@testable import Launcher

final class TerminalOutputSanitizerTests: XCTestCase {
    func testPreservesPrintableUnicodeNewlinesAndTabs() {
        var sanitizer = TerminalOutputSanitizer()

        XCTAssertEqual(
            sanitizer.sanitize("plain\ttext\nCaf\u{00E9} — \u{4F60}\u{597D} \u{1F680}"),
            "plain\ttext\nCaf\u{00E9} — \u{4F60}\u{597D} \u{1F680}"
        )
        XCTAssertEqual(sanitizer.finish(), "")
    }

    func testDropsC0C1AndDeleteControls() {
        let allowed: Set<Int> = [0x09, 0x0A, 0x0D]

        for value in Array(0x00...0x1F) + [0x7F] + Array(0x80...0x9F) where !allowed.contains(value) {
            guard let scalar = Unicode.Scalar(value) else {
                return XCTFail("Invalid test scalar: \(value)")
            }
            var sanitizer = TerminalOutputSanitizer()
            XCTAssertEqual(sanitizer.sanitize(String(scalar)), "", "U+\(String(value, radix: 16))")
            XCTAssertEqual(sanitizer.finish(), "", "U+\(String(value, radix: 16))")
        }
    }

    func testNormalizesCRLFAndStandaloneCarriageReturnsAcrossChunks() {
        var sanitizer = TerminalOutputSanitizer()

        XCTAssertEqual(sanitizer.sanitize("first\r"), "first")
        XCTAssertEqual(sanitizer.sanitize("\nsecond\rprogress\r"), "\nsecond\nprogress")
        XCTAssertEqual(sanitizer.sanitize("done"), "\ndone")
        XCTAssertEqual(sanitizer.sanitize("\r"), "")
        XCTAssertEqual(sanitizer.finish(), "\n")
    }

    func testStripsCSIAcrossChunkBoundariesIncludingC1Form() {
        var sanitizer = TerminalOutputSanitizer()

        XCTAssertEqual(sanitizer.sanitize("before \u{1B}[3"), "before ")
        XCTAssertEqual(sanitizer.sanitize("1mred\u{1B}[0"), "red")
        XCTAssertEqual(sanitizer.sanitize("m and \u{9B}2Kafter"), " and after")
        XCTAssertEqual(sanitizer.finish(), "")
    }

    func testPreservesTextControlsInsideCSIAndEscapeIntermediateSequences() {
        var sanitizer = TerminalOutputSanitizer()

        XCTAssertEqual(sanitizer.sanitize("a\u{1B}[31\r"), "a")
        XCTAssertEqual(sanitizer.sanitize("\n\tmb\u{1B}(\r"), "\n\tb")
        XCTAssertEqual(sanitizer.sanitize("\nBc"), "\nc")
        XCTAssertEqual(sanitizer.finish(), "")
    }

    func testStripsOSC8AndOSC52WithBELAndSplitSTTerminators() {
        var sanitizer = TerminalOutputSanitizer()

        XCTAssertEqual(sanitizer.sanitize("a\u{1B}]8;;https://example.com"), "a")
        XCTAssertEqual(sanitizer.sanitize("\u{7}link\u{1B}]8;;\u{1B}"), "link")
        XCTAssertEqual(sanitizer.sanitize("\\ b"), " b")
        XCTAssertEqual(sanitizer.sanitize("\u{9D}52;c;c2VjcmV0\u{9C}safe"), "safe")
        XCTAssertEqual(sanitizer.finish(), "")
    }

    func testStripsDCSAPCPMSOSStrings() {
        let introducers = ["P", "_", "^", "X"]

        for introducer in introducers {
            var sanitizer = TerminalOutputSanitizer()
            XCTAssertEqual(
                sanitizer.sanitize("left\u{1B}\(introducer)ignored\u{1B}\\right"),
                "leftright",
                "ESC \(introducer)"
            )
        }
    }

    func testDoesNotRetainLargeControlStringPayload() {
        var sanitizer = TerminalOutputSanitizer()

        XCTAssertEqual(sanitizer.sanitize("start\u{1B}]52;c;"), "start")
        for _ in 0..<128 {
            XCTAssertEqual(sanitizer.sanitize(String(repeating: "x", count: 8_192)), "")
        }
        XCTAssertEqual(sanitizer.sanitize("\u{1B}\\end"), "end")
    }

    func testStripsSingleCharacterAndIntermediateEscapeSequences() {
        var sanitizer = TerminalOutputSanitizer()

        XCTAssertEqual(
            sanitizer.sanitize("a\u{1B}7b\u{1B}(Bc\u{1B}cend"),
            "abcend"
        )
    }

    func testFinishDropsIncompleteSequenceAndResetsForReuse() {
        var sanitizer = TerminalOutputSanitizer()

        XCTAssertEqual(sanitizer.sanitize("shown\u{1B}]unterminated"), "shown")
        XCTAssertEqual(sanitizer.finish(), "")
        XCTAssertEqual(sanitizer.sanitize("visible"), "visible")
        XCTAssertEqual(sanitizer.finish(), "")
    }
}
