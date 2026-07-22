import XCTest
@testable import Launcher

final class FileBrowserEngineTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var lockedDirectory: URL!

    override func setUpWithError() throws {
        let fileManager = FileManager.default
        root = fileManager.temporaryDirectory
            .appendingPathComponent("file-browser-tests-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)

        try fileManager.createDirectory(at: home.appendingPathComponent("Alpha"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: home.appendingPathComponent("beta"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: home.appendingPathComponent("Fake.app"), withIntermediateDirectories: true)
        try "inner".write(to: home.appendingPathComponent("Alpha/Inner.txt"), atomically: true, encoding: .utf8)
        try "notes".write(to: home.appendingPathComponent("Notes.txt"), atomically: true, encoding: .utf8)
        try "readme".write(to: home.appendingPathComponent("Read Me.md"), atomically: true, encoding: .utf8)
        try "hidden".write(to: home.appendingPathComponent(".hidden.txt"), atomically: true, encoding: .utf8)
        try fileManager.createSymbolicLink(
            at: home.appendingPathComponent("LinkToAlpha"),
            withDestinationURL: home.appendingPathComponent("Alpha")
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: home.appendingPathComponent("Alpha").path
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: home.appendingPathComponent("Notes.txt").path
        )

        lockedDirectory = home.appendingPathComponent("locked", isDirectory: true)
        try fileManager.createDirectory(at: lockedDirectory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedDirectory.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedDirectory.path)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - isPathLike

    func testIsPathLike() {
        XCTAssertTrue(FileBrowserEngine.isPathLike("/"))
        XCTAssertTrue(FileBrowserEngine.isPathLike("/Users"))
        XCTAssertTrue(FileBrowserEngine.isPathLike("~"))
        XCTAssertTrue(FileBrowserEngine.isPathLike("~/Desktop"))
        XCTAssertTrue(FileBrowserEngine.isPathLike("./notes"))
        XCTAssertTrue(FileBrowserEngine.isPathLike("../notes"))

        XCTAssertFalse(FileBrowserEngine.isPathLike(""))
        XCTAssertFalse(FileBrowserEngine.isPathLike("hello"))
        XCTAssertFalse(FileBrowserEngine.isPathLike("5+5"))
        XCTAssertFalse(FileBrowserEngine.isPathLike("~notes"))
    }

    // MARK: - parse

    func testParseBareTildeAndRootListWithoutFilter() {
        XCTAssertEqual(
            FileBrowserEngine.parse("~", home: home),
            FileBrowserEngine.BrowseRequest(directory: home.standardizedFileURL, filter: "")
        )
        XCTAssertEqual(
            FileBrowserEngine.parse("/", home: home),
            FileBrowserEngine.BrowseRequest(directory: URL(fileURLWithPath: "/"), filter: "")
        )
    }

    func testParseSplitsLastComponentAsFilter() {
        XCTAssertEqual(
            FileBrowserEngine.parse("~/Alp", home: home),
            FileBrowserEngine.BrowseRequest(directory: home.standardizedFileURL, filter: "Alp")
        )
        XCTAssertEqual(
            FileBrowserEngine.parse("/Users", home: home),
            FileBrowserEngine.BrowseRequest(directory: URL(fileURLWithPath: "/"), filter: "Users")
        )
    }

    func testParseTrailingSlashListsDirectory() {
        let request = FileBrowserEngine.parse("~/Alpha/", home: home)
        XCTAssertEqual(request?.directory.path, home.appendingPathComponent("Alpha").standardizedFileURL.path)
        XCTAssertEqual(request?.filter, "")
    }

    func testParseRelativePathsResolveAgainstHome() {
        XCTAssertEqual(
            FileBrowserEngine.parse("./Alp", home: home),
            FileBrowserEngine.BrowseRequest(directory: home.standardizedFileURL, filter: "Alp")
        )
        XCTAssertEqual(
            FileBrowserEngine.parse("../ho", home: home),
            FileBrowserEngine.BrowseRequest(directory: root.standardizedFileURL, filter: "ho")
        )
    }

    func testParseRejectsNonPathQueries() {
        XCTAssertNil(FileBrowserEngine.parse("hello", home: home))
        XCTAssertNil(FileBrowserEngine.parse("5+5", home: home))
    }

    // MARK: - list

    func testListSplitsSectionsAndSortsByName() {
        let listing = FileBrowserEngine.list(directory: home, filter: "", home: home)

        XCTAssertNil(listing.error)
        XCTAssertEqual(listing.directories.map(\.name), ["Alpha", "beta", "LinkToAlpha", "locked"].sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        })
        XCTAssertEqual(listing.files.map(\.name), ["Fake.app", "Notes.txt", "Read Me.md"].sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        })
    }

    func testListReportsPermissions() {
        let listing = FileBrowserEngine.list(directory: home, filter: "", home: home)

        XCTAssertEqual(listing.directories.first { $0.name == "Alpha" }?.permissions, "755")
        XCTAssertEqual(listing.files.first { $0.name == "Notes.txt" }?.permissions, "644")
    }

    func testSymlinkToDirectoryCountsAsDirectory() {
        let listing = FileBrowserEngine.list(directory: home, filter: "", home: home)
        XCTAssertTrue(listing.directories.contains { $0.name == "LinkToAlpha" })
    }

    func testPackageDirectoryCountsAsFile() {
        let listing = FileBrowserEngine.list(directory: home, filter: "", home: home)
        XCTAssertTrue(listing.files.contains { $0.name == "Fake.app" })
    }

    func testHiddenFilesRequireDotFilter() {
        let withoutDot = FileBrowserEngine.list(directory: home, filter: "", home: home)
        XCTAssertFalse(withoutDot.files.contains { $0.name == ".hidden.txt" })

        let withDot = FileBrowserEngine.list(directory: home, filter: ".hid", home: home)
        XCTAssertTrue(withDot.files.contains { $0.name == ".hidden.txt" })
    }

    func testFilterMatchesPrefixAndFuzzy() {
        let prefix = FileBrowserEngine.list(directory: home, filter: "Alp", home: home)
        XCTAssertTrue(prefix.directories.contains { $0.name == "Alpha" })
        XCTAssertFalse(prefix.files.contains { $0.name == "Notes.txt" })

        let fuzzy = FileBrowserEngine.list(directory: home, filter: "rdme", home: home)
        XCTAssertTrue(fuzzy.files.contains { $0.name == "Read Me.md" })
    }

    func testUnreadableDirectoryReportsError() {
        let listing = FileBrowserEngine.list(directory: lockedDirectory, filter: "", home: home)
        XCTAssertEqual(listing.error, .notReadable)
        XCTAssertTrue(listing.isEmpty)
    }

    func testMissingDirectoryReportsError() {
        let listing = FileBrowserEngine.list(
            directory: home.appendingPathComponent("does-not-exist"),
            filter: "",
            home: home
        )
        XCTAssertEqual(listing.error, .notFound)
    }

    func testListTruncatesLargeDirectories() throws {
        let big = root.appendingPathComponent("big", isDirectory: true)
        try FileManager.default.createDirectory(at: big, withIntermediateDirectories: true)
        for index in 0..<(FileBrowserEngine.maxEntries + 5) {
            try "x".write(to: big.appendingPathComponent("file-\(index).txt"), atomically: true, encoding: .utf8)
        }

        let listing = FileBrowserEngine.list(directory: big, filter: "", home: home)
        XCTAssertTrue(listing.isTruncated)
        XCTAssertEqual(listing.directories.count + listing.files.count, FileBrowserEngine.maxEntries)
    }

    // MARK: - iCloud Drive pin

    func testICloudEntryPinnedWhenListingHome() throws {
        let cloudDocs = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        try FileManager.default.createDirectory(at: cloudDocs, withIntermediateDirectories: true)

        let listing = FileBrowserEngine.list(directory: home, filter: "", home: home)
        XCTAssertEqual(listing.iCloudEntry?.name, FileBrowserEngine.iCloudDriveName)
        XCTAssertEqual(listing.iCloudEntry?.url.standardizedFileURL.path, cloudDocs.standardizedFileURL.path)
        XCTAssertEqual(listing.iCloudEntry?.isDirectory, true)

        let elsewhere = FileBrowserEngine.list(directory: home.appendingPathComponent("Alpha"), filter: "", home: home)
        XCTAssertNil(elsewhere.iCloudEntry)

        let filteredOut = FileBrowserEngine.list(directory: home, filter: "zzz", home: home)
        XCTAssertNil(filteredOut.iCloudEntry)
    }

    func testNoICloudEntryWithoutCloudDocsDirectory() {
        let listing = FileBrowserEngine.list(directory: home, filter: "", home: home)
        XCTAssertNil(listing.iCloudEntry)
    }
}
