import XCTest
@testable import Launcher

final class SearchMatcherTests: XCTestCase {
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
