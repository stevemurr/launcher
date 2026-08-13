import XCTest
@testable import Launcher

final class SearchMatcherTests: XCTestCase {
    func testPreparedQueryMatchesDirectScoring() {
        let prepared = SearchMatcher.prepare("  résumé edi  ")

        XCTAssertEqual(
            SearchMatcher.score(query: prepared, title: "Resume Editor", keywords: "documents"),
            SearchMatcher.score(query: "  résumé edi  ", title: "Resume Editor", keywords: "documents")
        )
    }

    func testPrefixRanksAheadOfSubstring() {
        let prefix = SearchMatcher.score(query: "act", title: "Activity Monitor")
        let substring = SearchMatcher.score(query: "act", title: "Folder Actions Setup")
        XCTAssertNotNil(prefix)
        XCTAssertNotNil(substring)
        XCTAssertGreaterThan(prefix!, substring!)
    }

    func testFuzzyMatchFindsApplication() {
        XCTAssertNotNil(SearchMatcher.score(query: "acmn", title: "Activity Monitor"))
    }

    func testUnrelatedQueryDoesNotMatch() {
        XCTAssertNil(SearchMatcher.score(query: "zzqx", title: "Activity Monitor"))
    }

    func testKeywordCanMatchSystemSetting() {
        XCTAssertNotNil(SearchMatcher.score(
            query: "microphone",
            title: "Privacy & Security",
            keywords: "location camera microphone permissions"
        ))
    }
}
