import AppKit
import XCTest
@testable import Launcher

private final class QuietLoginItems: LoginItemService {
    var isEnabled = false
    func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}

final class LauncherModelFileBrowserTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var scriptsDirectory: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        let fileManager = FileManager.default
        root = fileManager.temporaryDirectory
            .appendingPathComponent("model-browser-tests-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        scriptsDirectory = root.appendingPathComponent("scripts", isDirectory: true)

        try fileManager.createDirectory(at: home.appendingPathComponent("Alpha"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)
        try "inner".write(to: home.appendingPathComponent("Alpha/Inner.txt"), atomically: true, encoding: .utf8)
        try "notes".write(to: home.appendingPathComponent("Notes.txt"), atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: home.appendingPathComponent("Alpha").path
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: home.appendingPathComponent("Notes.txt").path
        )

        defaults = UserDefaults(suiteName: "LauncherModelFileBrowserTests-\(UUID().uuidString)")!
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeModel() -> LauncherModel {
        let settings = LauncherSettings(defaults: defaults)
        settings.save(scriptsDirectory: scriptsDirectory)
        return LauncherModel(
            settings: settings,
            isUITesting: false,
            loginItems: QuietLoginItems(),
            browseHome: home
        )
    }

    private func selectItem(titled title: String, in model: LauncherModel) {
        guard let index = model.results.firstIndex(where: { $0.title == title }) else {
            XCTFail("no result titled \(title) in \(model.results.map(\.title))")
            return
        }
        model.select(index: index)
    }

    // MARK: - Derived browsing

    func testPathQueryShowsDirectoryListing() {
        let model = makeModel()
        model.query = "~/"

        XCTAssertTrue(model.isFileBrowsing)
        XCTAssertNil(model.calculation)
        XCTAssertNil(model.browseSession)
        XCTAssertEqual(model.results.map(\.title), ["Alpha", "Notes.txt"])
        XCTAssertEqual(model.results[0].kind, .directory)
        XCTAssertEqual(model.results[0].detail, "755")
        XCTAssertEqual(model.results[1].kind, .file)
        XCTAssertEqual(model.results[1].detail, "644")
    }

    func testPathQueryResolvesSynchronouslyForTestModels() {
        // Unit test models are constructed with a fixed `browseHome`, so the
        // listing must still resolve on the same run-loop turn as the query
        // change (no background dispatch / generation lag) after the async
        // offload was added for real (non-test) usage.
        let model = makeModel()
        model.query = "~/"

        XCTAssertEqual(model.fileListing?.directory.standardizedFileURL.path, home.standardizedFileURL.path)
        XCTAssertEqual(model.results.map(\.title), ["Alpha", "Notes.txt"])
    }

    func testLastPathComponentFiltersListing() {
        let model = makeModel()
        model.query = "~/Alp"

        XCTAssertEqual(model.results.map(\.title), ["Alpha"])
    }

    func testNonPathQueryExitsDerivedBrowsing() {
        let model = makeModel()
        model.query = "~/"
        XCTAssertTrue(model.isFileBrowsing)

        model.query = "launcher"
        XCTAssertFalse(model.isFileBrowsing)
        XCTAssertTrue(model.results.contains { $0.title == "Launcher Settings" })
    }

    func testLateAsyncListingCannotReplaceNewerNormalSearch() {
        let settings = LauncherSettings(defaults: defaults)
        settings.save(scriptsDirectory: scriptsDirectory)
        let model = LauncherModel(
            settings: settings,
            isUITesting: false,
            loginItems: QuietLoginItems()
        )

        model.query = root.path + "/"
        model.query = "launcher"

        let settled = expectation(description: "background listing settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            XCTAssertFalse(model.isFileBrowsing)
            XCTAssertEqual(model.query, "launcher")
            XCTAssertTrue(model.results.contains { $0.title == "Launcher Settings" })
            settled.fulfill()
        }
        wait(for: [settled], timeout: 2)
    }

    func testPendingPathListingImmediatelyInvalidatesPreviousAction() {
        let started = expectation(description: "listing started")
        let gate = DispatchSemaphore(value: 0)
        let settings = LauncherSettings(defaults: defaults)
        settings.save(scriptsDirectory: scriptsDirectory)
        let model = LauncherModel(
            settings: settings,
            isUITesting: false,
            loginItems: QuietLoginItems(),
            browseHome: home,
            resolvesFileListingsSynchronously: false,
            fileListingResolver: { _, _, home in
                started.fulfill()
                gate.wait()
                return FileListing(
                    directory: home,
                    iCloudEntry: nil,
                    directories: [],
                    files: [],
                    error: nil,
                    isTruncated: false
                )
            }
        )

        model.query = "5+5"
        XCTAssertEqual(model.selectedItem?.kind, .calculator)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("unchanged", forType: .string)

        model.query = "~/"

        XCTAssertTrue(model.isFileListingLoading)
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertNil(model.selectedItem)
        model.handleSubmit()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "unchanged")

        wait(for: [started], timeout: 2)
        gate.signal()
        let deadline = Date().addingTimeInterval(2)
        while model.isFileListingLoading, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertFalse(model.isFileListingLoading)
    }

    func testPendingDerivedListingKeepsFileDirectoryInAccessibilityLabel() {
        let started = expectation(description: "listing started")
        let gate = DispatchSemaphore(value: 0)
        let settings = LauncherSettings(defaults: defaults)
        settings.save(scriptsDirectory: scriptsDirectory)
        let model = LauncherModel(
            settings: settings,
            isUITesting: false,
            loginItems: QuietLoginItems(),
            browseHome: home,
            resolvesFileListingsSynchronously: false,
            fileListingResolver: { _, _, home in
                started.fulfill()
                gate.wait()
                return FileListing(
                    directory: home.appendingPathComponent("Alpha", isDirectory: true),
                    iCloudEntry: nil,
                    directories: [],
                    files: [],
                    error: nil,
                    isTruncated: false
                )
            }
        )

        model.query = "~/Alpha/"

        let pendingDirectory = home.appendingPathComponent("Alpha", isDirectory: true).standardizedFileURL
        XCTAssertTrue(model.isFileListingLoading)
        XCTAssertNil(model.fileListing)
        XCTAssertEqual(
            model.browseDirectoryForAccessibility?.standardizedFileURL.path,
            pendingDirectory.path
        )
        XCTAssertEqual(
            LauncherSearchField.contextualAccessibilityLabel(
                for: model.browseDirectoryForAccessibility
            ),
            "Search files in \(pendingDirectory.path)/"
        )

        wait(for: [started], timeout: 2)
        gate.signal()
        let deadline = Date().addingTimeInterval(2)
        while model.isFileListingLoading, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertFalse(model.isFileListingLoading)
    }

    func testRapidPathChangesAreCoalescedAndStayBounded() {
        let firstStarted = expectation(description: "first listing started")
        let latestStarted = expectation(description: "latest listing started")
        let firstGate = DispatchSemaphore(value: 0)
        defer { firstGate.signal() }
        let lock = NSLock()
        var calls = 0
        var active = 0
        var maximumActive = 0
        let settings = LauncherSettings(defaults: defaults)
        settings.save(scriptsDirectory: scriptsDirectory)
        let model = LauncherModel(
            settings: settings,
            isUITesting: false,
            loginItems: QuietLoginItems(),
            browseHome: home,
            resolvesFileListingsSynchronously: false,
            fileListingResolver: { _, _, home in
                lock.lock()
                calls += 1
                let call = calls
                active += 1
                maximumActive = max(maximumActive, active)
                lock.unlock()

                if call == 1 {
                    firstStarted.fulfill()
                    firstGate.wait()
                } else if call == 2 {
                    latestStarted.fulfill()
                }

                lock.lock()
                active -= 1
                lock.unlock()
                return FileListing(
                    directory: home,
                    iCloudEntry: nil,
                    directories: [],
                    files: [],
                    error: nil,
                    isTruncated: false
                )
            }
        )

        model.query = "~/first"
        wait(for: [firstStarted], timeout: 2)

        for index in 0..<100 {
            model.query = "~/latest-\(index)"
        }
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertTrue(model.isFileListingLoading)

        wait(for: [latestStarted], timeout: 3)
        let latestDeadline = Date().addingTimeInterval(2)
        while model.isFileListingLoading, Date() < latestDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertFalse(
            model.isFileListingLoading,
            "the latest local request must finish without waiting for an obsolete blocked read"
        )
        firstGate.signal()
        let deadline = Date().addingTimeInterval(2)
        while model.isFileListingLoading, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        lock.lock()
        let finalCalls = calls
        let finalMaximumActive = maximumActive
        lock.unlock()
        XCTAssertEqual(finalCalls, 2, "one active and only the latest pending request should run")
        XCTAssertEqual(finalMaximumActive, 2, "one newest request may overtake one obsolete blocked read")
        XCTAssertFalse(model.isFileListingLoading)
    }

    func testTwoHungListingsKeepOnlyNewestPendingRequest() {
        let firstStarted = expectation(description: "first listing started")
        let secondStarted = expectation(description: "second listing started")
        let newestStarted = expectation(description: "newest pending listing started")
        let firstGate = DispatchSemaphore(value: 0)
        let secondGate = DispatchSemaphore(value: 0)
        defer {
            firstGate.signal()
            secondGate.signal()
        }

        let lock = NSLock()
        var requestedQueries: [String] = []
        var active = 0
        var maximumActive = 0
        let settings = LauncherSettings(defaults: defaults)
        settings.save(scriptsDirectory: scriptsDirectory)
        let model = LauncherModel(
            settings: settings,
            isUITesting: false,
            loginItems: QuietLoginItems(),
            browseHome: home,
            resolvesFileListingsSynchronously: false,
            fileListingResolver: { _, query, home in
                lock.lock()
                requestedQueries.append(query)
                let call = requestedQueries.count
                active += 1
                maximumActive = max(maximumActive, active)
                lock.unlock()

                switch call {
                case 1:
                    firstStarted.fulfill()
                    firstGate.wait()
                case 2:
                    secondStarted.fulfill()
                    secondGate.wait()
                case 3:
                    newestStarted.fulfill()
                default:
                    break
                }

                let name = String(query.dropFirst(2))
                lock.lock()
                active -= 1
                lock.unlock()
                return FileListing(
                    directory: home,
                    iCloudEntry: nil,
                    directories: [],
                    files: [
                        FileEntry(
                            url: home.appendingPathComponent(name),
                            name: name,
                            isDirectory: false,
                            permissions: "644"
                        )
                    ],
                    error: nil,
                    isTruncated: false
                )
            }
        )

        model.query = "~/hung-first"
        wait(for: [firstStarted], timeout: 2)
        model.query = "~/hung-second"
        wait(for: [secondStarted], timeout: 2)

        for index in 0..<100 {
            model.query = "~/pending-\(index)"
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        lock.lock()
        let callsWhileHung = requestedQueries.count
        let maximumWhileHung = maximumActive
        lock.unlock()
        XCTAssertEqual(callsWhileHung, 2, "two occupied lanes must retain newer input without starting it")
        XCTAssertEqual(maximumWhileHung, 2)

        firstGate.signal()
        wait(for: [newestStarted], timeout: 2)
        let completionDeadline = Date().addingTimeInterval(2)
        while model.isFileListingLoading, Date() < completionDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        lock.lock()
        let queriesAfterNewest = requestedQueries
        let finalMaximumActive = maximumActive
        lock.unlock()
        XCTAssertEqual(queriesAfterNewest, ["~/hung-first", "~/hung-second", "~/pending-99"])
        XCTAssertEqual(finalMaximumActive, 2)
        XCTAssertEqual(model.results.map(\.title), ["pending-99"])
        XCTAssertFalse(model.isFileListingLoading)

        secondGate.signal()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        lock.lock()
        let finalCallCount = requestedQueries.count
        lock.unlock()
        XCTAssertEqual(finalCallCount, 3, "releasing both lanes must not reveal a backlog of superseded work")
    }

    func testCatalogUpdateDoesNotRestartInFlightFileListing() {
        let listingStarted = expectation(description: "listing started")
        let releaseListing = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var listingCalls = 0
        let settings = LauncherSettings(defaults: defaults)
        settings.save(scriptsDirectory: scriptsDirectory)
        let model = LauncherModel(
            settings: settings,
            isUITesting: false,
            loginItems: QuietLoginItems(),
            browseHome: home,
            resolvesFileListingsSynchronously: false,
            fileListingResolver: { _, _, home in
                lock.lock()
                listingCalls += 1
                lock.unlock()
                listingStarted.fulfill()
                releaseListing.wait()
                return FileListing(
                    directory: home,
                    iCloudEntry: nil,
                    directories: [],
                    files: [],
                    error: nil,
                    isTruncated: false
                )
            },
            scriptDiscoverer: { _ in [] }
        )

        model.query = "~/"
        wait(for: [listingStarted], timeout: 2)
        model.rescanScripts()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        releaseListing.signal()

        let deadline = Date().addingTimeInterval(2)
        while model.isFileListingLoading, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        lock.lock()
        let finalCalls = listingCalls
        lock.unlock()
        XCTAssertEqual(finalCalls, 1)
        XCTAssertFalse(model.isFileListingLoading)
    }

    func testEscapeInDerivedModeClearsQueryWithoutClosing() {
        var closed = false
        let model = makeModel()
        model.onRequestClose = { closed = true }
        model.query = "~/"

        model.handleEscape()

        XCTAssertEqual(model.query, "")
        XCTAssertFalse(model.isFileBrowsing)
        XCTAssertFalse(closed)
    }

    // MARK: - Sticky browsing

    func testSubmitOnDirectoryDescends() {
        let model = makeModel()
        model.query = "~/"
        selectItem(titled: "Alpha", in: model)

        model.handleSubmit()

        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.browseSession?.current.lastPathComponent, "Alpha")
        XCTAssertTrue(model.searchFieldPlaceholder.contains("Alpha"))
        XCTAssertEqual(model.results.map(\.title), ["Inner.txt"])
    }

    func testStickyModeTreatsQueryAsFilter() {
        let model = makeModel()
        model.query = "~/"
        selectItem(titled: "Alpha", in: model)
        model.handleSubmit()

        model.query = "zzz"

        XCTAssertNotNil(model.browseSession)
        XCTAssertTrue(model.isFileBrowsing)
        XCTAssertTrue(model.results.isEmpty)

        model.query = "Inner"
        XCTAssertEqual(model.results.map(\.title), ["Inner.txt"])
    }

    func testEscapeWalksUpThenExitsBeforeClosing() {
        var closed = false
        let model = makeModel()
        model.onRequestClose = { closed = true }
        model.query = "~/"
        selectItem(titled: "Alpha", in: model)
        model.handleSubmit()

        // Stack is [home, Alpha]: first escape returns to the home listing.
        model.handleEscape()
        XCTAssertEqual(model.browseSession?.current.path, home.standardizedFileURL.path)
        XCTAssertTrue(model.isFileBrowsing)
        XCTAssertFalse(closed)

        // Second escape leaves browse mode entirely.
        model.handleEscape()
        XCTAssertNil(model.browseSession)
        XCTAssertFalse(model.isFileBrowsing)
        XCTAssertEqual(model.query, "")
        XCTAssertTrue(model.results.contains { $0.title == "Launcher Settings" })
        XCTAssertFalse(closed)

        // Third escape closes the window as usual.
        model.handleEscape()
        XCTAssertTrue(closed)
    }

    func testPrepareForPresentationClearsBrowseState() {
        let model = makeModel()
        model.query = "~/"
        selectItem(titled: "Alpha", in: model)
        model.handleSubmit()

        model.prepareForPresentation(screen: .search)

        XCTAssertNil(model.browseSession)
        XCTAssertFalse(model.isFileBrowsing)
        XCTAssertEqual(model.query, "")
    }

    func testOpeningSettingsAfterStickyBrowseCannotLeaveOrphanedListing() {
        var closed = false
        let model = makeModel()
        model.onRequestClose = { closed = true }
        model.query = "~/"
        selectItem(titled: "Alpha", in: model)
        model.handleSubmit()
        XCTAssertNotNil(model.browseSession)
        XCTAssertEqual(model.query, "")

        model.prepareForPresentation(screen: .settings)
        model.showSearch()

        XCTAssertNil(model.browseSession)
        XCTAssertNil(model.fileListing)
        XCTAssertFalse(model.isFileBrowsing)
        XCTAssertFalse(model.results.contains { $0.kind == .file || $0.kind == .directory })
        model.handleEscape()
        XCTAssertTrue(closed, "Escape must still make progress after returning from Settings")
    }

    func testApplicationRefreshPreservesSelectedItemIdentity() {
        let model = LauncherModel(
            settings: LauncherSettings(defaults: defaults),
            isUITesting: true,
            loginItems: QuietLoginItems()
        )
        model.loadApplications()
        let calculatorIndex = model.results.firstIndex { $0.id == "application.com.apple.calculator" }!
        model.select(index: calculatorIndex)

        model.loadApplications()

        XCTAssertEqual(model.selectedItem?.id, "application.com.apple.calculator")
    }

    func testUnreadableDirectoryProducesErrorListing() throws {
        let locked = home.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let model = makeModel()
        model.query = "~/locked/"

        XCTAssertEqual(model.fileListing?.error, .notReadable)
        XCTAssertTrue(model.results.isEmpty)
    }

    // MARK: - Actions

    func testAvailableActionsForFileEntries() {
        let model = makeModel()
        model.query = "~/"
        selectItem(titled: "Notes.txt", in: model)

        XCTAssertEqual(model.availableActions, [.open, .openWith, .showInFinder, .quickLook, .copyPath])
    }

    func testQuickLookActionFiresCallback() {
        var previewed: URL?
        let model = makeModel()
        model.onQuickLook = { previewed = $0 }
        model.query = "~/"
        selectItem(titled: "Notes.txt", in: model)

        model.perform(.quickLook)

        XCTAssertEqual(previewed?.lastPathComponent, "Notes.txt")
    }

    func testCopyPathActionCopiesFilePath() {
        let model = makeModel()
        model.query = "~/"
        selectItem(titled: "Notes.txt", in: model)

        model.perform(.copyPath)

        // The temporary directory is reachable both as /var/… and /private/var/…,
        // so compare with symlinks resolved on both sides.
        let copied = NSPasteboard.general.string(forType: .string).map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }
        XCTAssertEqual(
            copied,
            home.appendingPathComponent("Notes.txt").resolvingSymlinksInPath().path
        )
    }

    func testShowInFinderDismissesBeforeRevealingItem() {
        let model = makeModel()
        model.query = "~/"
        selectItem(titled: "Notes.txt", in: model)
        var events: [String] = []

        model.onRequestClose = { events.append("dismiss") }
        model.fileRevealer = { url in
            XCTAssertEqual(url.lastPathComponent, "Notes.txt")
            events.append("reveal")
        }

        model.perform(.showInFinder)

        XCTAssertEqual(events, ["dismiss", "reveal"])
    }

    // MARK: - Actions palette selection

    func testArrowSelectionMovesThroughListing() {
        let model = makeModel()
        model.query = "~/"

        XCTAssertEqual(model.results[model.selectedIndex].title, "Alpha")
        model.moveSelection(by: 1)
        XCTAssertEqual(model.results[model.selectedIndex].title, "Notes.txt")
        model.moveSelection(by: -1)
        XCTAssertEqual(model.results[model.selectedIndex].title, "Alpha")
    }

    func testActionsPaletteCapturesArrowsAndSubmit() {
        let model = makeModel()
        model.applicationFinder = { _ in [URL(fileURLWithPath: "/System/Applications/TextEdit.app")] }
        model.query = "~/"
        selectItem(titled: "Notes.txt", in: model)

        model.toggleActions()
        XCTAssertTrue(model.isActionsPresented)
        XCTAssertEqual(model.actionsSelectionIndex, 0)

        let resultSelection = model.selectedIndex
        model.moveSelection(by: 1)
        XCTAssertEqual(model.actionsSelectionIndex, 1)
        XCTAssertEqual(model.selectedIndex, resultSelection, "arrows must not move the results selection")

        model.moveSelection(by: -2)
        XCTAssertEqual(model.actionsSelectionIndex, model.availableActions.count - 1, "selection wraps around")

        // Back to index 1 (Open With…) and submit it.
        model.moveSelection(by: 2)
        XCTAssertEqual(model.availableActions[model.actionsSelectionIndex], .openWith)
        model.handleSubmit()

        XCTAssertFalse(model.isActionsPresented)
        XCTAssertTrue(model.isOpenWithPresented)
    }

    func testActionsPaletteSelectionResetsOnReopen() {
        let model = makeModel()
        model.query = "~/"
        selectItem(titled: "Notes.txt", in: model)

        model.toggleActions()
        model.moveSelection(by: 2)
        XCTAssertEqual(model.actionsSelectionIndex, 2)

        model.toggleActions()
        model.toggleActions()
        XCTAssertEqual(model.actionsSelectionIndex, 0)
    }

    func testActionsPaletteKeepsTheItemItWasOpenedFor() {
        let model = makeModel()
        model.query = "~/"
        selectItem(titled: "Notes.txt", in: model)
        model.toggleActions()
        XCTAssertEqual(model.actionsTarget?.title, "Notes.txt")

        // Simulate a result-row hover changing the live selection behind the
        // palette after it was presented.
        model.selectedIndex = model.results.firstIndex { $0.title == "Alpha" }!
        model.perform(.copyPath)

        let copied = NSPasteboard.general.string(forType: .string).map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }
        XCTAssertEqual(
            copied,
            home.appendingPathComponent("Notes.txt").resolvingSymlinksInPath().path
        )
    }

    func testChangingQueryDismissesActionsPalette() {
        let model = makeModel()
        model.query = "~/"
        selectItem(titled: "Notes.txt", in: model)
        model.toggleActions()

        model.query = "launcher"

        XCTAssertFalse(model.isActionsPresented)
        XCTAssertNil(model.actionsTarget)
    }

    // MARK: - Open With

    func testOpenWithPaletteFlow() {
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let notesApp = URL(fileURLWithPath: "/System/Applications/Notes.app")
        var opened: (file: URL, application: URL)?
        var closed = false
        var events: [String] = []

        let model = makeModel()
        model.applicationFinder = { _ in [textEdit, notesApp] }
        model.applicationOpener = {
            opened = (file: $0, application: $1)
            events.append("open")
        }
        model.onRequestClose = {
            closed = true
            events.append("dismiss")
        }
        model.query = "~/"
        selectItem(titled: "Notes.txt", in: model)

        model.perform(.openWith)
        XCTAssertTrue(model.isOpenWithPresented)
        XCTAssertEqual(model.openWithApps.map(\.url), [textEdit, notesApp])
        XCTAssertEqual(model.openWithSelectionIndex, 0)

        let resultSelection = model.selectedIndex
        model.moveSelection(by: 1)
        XCTAssertEqual(model.openWithSelectionIndex, 1)
        XCTAssertEqual(model.selectedIndex, resultSelection)

        model.handleSubmit()
        XCTAssertFalse(model.isOpenWithPresented)
        XCTAssertEqual(opened?.file.lastPathComponent, "Notes.txt")
        XCTAssertEqual(opened?.application, notesApp)
        XCTAssertTrue(closed)
        XCTAssertEqual(events, ["dismiss", "open"])
    }

    func testEscapeDismissesOpenWithPaletteFirst() {
        var closed = false
        let model = makeModel()
        model.applicationFinder = { _ in [URL(fileURLWithPath: "/System/Applications/TextEdit.app")] }
        model.onRequestClose = { closed = true }
        model.query = "~/"
        selectItem(titled: "Notes.txt", in: model)
        model.perform(.openWith)

        model.handleEscape()

        XCTAssertFalse(model.isOpenWithPresented)
        XCTAssertTrue(model.isFileBrowsing)
        XCTAssertFalse(closed)
    }

    func testConfirmOpenWithUsesSnapshottedTargetNotLiveSelection() {
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        var opened: (file: URL, application: URL)?

        let model = makeModel()
        model.applicationFinder = { _ in [textEdit] }
        model.applicationOpener = { opened = (file: $0, application: $1) }
        model.query = "~/"
        selectItem(titled: "Notes.txt", in: model)

        model.perform(.openWith)
        XCTAssertTrue(model.isOpenWithPresented)

        // A stray hover over another row while the palette is up moves the
        // live selection; the palette must still act on the file it was
        // presented for.
        selectItem(titled: "Alpha", in: model)

        model.confirmOpenWith()

        XCTAssertEqual(
            opened?.file.lastPathComponent, "Notes.txt",
            "must open the file the palette was presented for, not the hovered row"
        )
        XCTAssertEqual(opened?.application, textEdit)
    }

    // MARK: - iCloud Drive pin

    func testICloudEntryAppearsFirstAndDescends() throws {
        let cloudDocs = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        try FileManager.default.createDirectory(at: cloudDocs, withIntermediateDirectories: true)

        let model = makeModel()
        model.query = "~/"

        XCTAssertEqual(model.results.first?.id, "file.icloud")
        XCTAssertEqual(model.results.first?.title, "iCloud Drive")
        XCTAssertEqual(model.results.first?.kind, .directory)
        XCTAssertNil(model.results.first?.detail)

        model.select(index: 0)
        model.handleSubmit()
        XCTAssertEqual(
            model.browseSession?.current.standardizedFileURL.path,
            cloudDocs.standardizedFileURL.path
        )
    }
}
