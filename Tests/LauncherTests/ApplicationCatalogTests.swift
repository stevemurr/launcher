import XCTest
@testable import Launcher

final class ApplicationCatalogTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var applicationsDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("application-catalog-tests-\(UUID().uuidString)", isDirectory: true)
        applicationsDirectory = temporaryDirectory.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationsDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testDiscoversHiddenRootLevelApplicationSymlink() throws {
        let systemApplications = temporaryDirectory
            .appendingPathComponent("Cryptexes/App/System/Applications", isDirectory: true)
        let safariBundle = systemApplications.appendingPathComponent("Safari.app", isDirectory: true)
        try createApplicationBundle(
            at: safariBundle,
            name: "Safari",
            bundleIdentifier: "com.apple.Safari"
        )

        var safariLink = applicationsDirectory.appendingPathComponent("Safari.app")
        try FileManager.default.createSymbolicLink(at: safariLink, withDestinationURL: safariBundle)
        var resourceValues = URLResourceValues()
        resourceValues.isHidden = true
        try safariLink.setResourceValues(resourceValues)

        let records = ApplicationCatalog.discoverApplications(in: [applicationsDirectory])

        XCTAssertEqual(records.map(\.id), ["com.apple.Safari"])
        XCTAssertEqual(records.first?.name, "Safari")
        XCTAssertEqual(records.first?.url.lastPathComponent, safariLink.lastPathComponent)
        XCTAssertEqual(
            records.first?.url.deletingLastPathComponent().lastPathComponent,
            applicationsDirectory.lastPathComponent
        )
    }

    func testDoesNotTraverseHiddenDirectories() throws {
        let hiddenDirectory = applicationsDirectory.appendingPathComponent(".internal", isDirectory: true)
        try createApplicationBundle(
            at: hiddenDirectory.appendingPathComponent("Helper.app", isDirectory: true),
            name: "Helper",
            bundleIdentifier: "com.example.Helper"
        )

        XCTAssertEqual(
            ApplicationCatalog.discoverApplications(in: [applicationsDirectory]),
            []
        )
    }

    private func createApplicationBundle(
        at url: URL,
        name: String,
        bundleIdentifier: String
    ) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let propertyList: [String: Any] = [
            "CFBundleDisplayName": name,
            "CFBundleExecutable": name,
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": name,
            "CFBundlePackageType": "APPL"
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
}
