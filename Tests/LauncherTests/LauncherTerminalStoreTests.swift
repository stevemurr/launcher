import XCTest
@testable import Launcher

@MainActor
final class LauncherTerminalStoreTests: XCTestCase {
    func testCreatesStableNamedSessionsAndSelectsNewestByDefault() throws {
        let store = LauncherTerminalStore()

        let first = store.createSession()
        let firstSession = try XCTUnwrap(store.session(for: first.id))
        let second = store.createSession()

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.displayName, "Shell 1")
        XCTAssertEqual(second.displayName, "Shell 2")
        XCTAssertEqual(first.phase, .idle)
        XCTAssertEqual(second.phase, .idle)
        XCTAssertEqual(first.workingDirectory, FileManager.default.homeDirectoryForCurrentUser.path)
        XCTAssertEqual(second.workingDirectory, FileManager.default.homeDirectoryForCurrentUser.path)
        XCTAssertEqual(store.summaries, [first, second])
        XCTAssertEqual(store.selectedSessionID, second.id)
        XCTAssertTrue(store.selectedSession === store.session(for: second.id))
        XCTAssertTrue(store.session(for: first.id) === firstSession)
    }

    func testSessionMetadataUpdatesItsPublishedSummary() throws {
        let store = LauncherTerminalStore()
        let created = store.createSession()
        let session = try XCTUnwrap(store.session(for: created.id))

        session.terminalDidChangeWorkingDirectory("/private/tmp/native-shell")
        session.terminalDidClose(processAlive: false)

        let summary = try XCTUnwrap(store.summaries.first { $0.id == created.id })
        XCTAssertEqual(summary.workingDirectory, "/private/tmp/native-shell")
        XCTAssertEqual(summary.phase, .exited)
    }

    func testEnsureSessionUsesModelIdentityAndIsIdempotent() {
        let store = LauncherTerminalStore()
        let id = ShellSessionID()

        let first = store.ensureSession(id: id, displayName: "Shell 7")
        let second = store.ensureSession(id: id, displayName: "Replacement Name")
        let generated = store.createSession()

        XCTAssertTrue(first === second)
        XCTAssertEqual(store.summaries.count, 2)
        XCTAssertEqual(store.summaries.first?.displayName, "Shell 7")
        XCTAssertEqual(store.summaries.last?.displayName, "Shell 8")
        XCTAssertEqual(store.selectedSessionID, generated.id)
    }

    func testClosingSelectedSessionClearsSelectionAndTerminatesOnlyClosedSession() throws {
        let store = LauncherTerminalStore()
        let first = store.createSession()
        let firstSession = try XCTUnwrap(store.session(for: first.id))
        let second = store.createSession()
        let secondSession = try XCTUnwrap(store.session(for: second.id))

        XCTAssertTrue(store.closeSession(second.id))

        XCTAssertNil(store.selectedSessionID)
        XCTAssertNil(store.selectedSession)
        XCTAssertNil(store.session(for: second.id))
        XCTAssertEqual(secondSession.phase, .exited)
        XCTAssertNotEqual(firstSession.phase, .exited)
        XCTAssertEqual(store.summaries, [first])
    }

    func testTerminateAllClearsRegistryAndTerminatesEverySession() throws {
        let store = LauncherTerminalStore()
        let first = store.createSession()
        let firstSession = try XCTUnwrap(store.session(for: first.id))
        let second = store.createSession()
        let secondSession = try XCTUnwrap(store.session(for: second.id))

        store.terminateAll()

        XCTAssertNil(store.selectedSessionID)
        XCTAssertNil(store.selectedSession)
        XCTAssertTrue(store.summaries.isEmpty)
        XCTAssertNil(store.session(for: first.id))
        XCTAssertNil(store.session(for: second.id))
        XCTAssertEqual(firstSession.phase, .exited)
        XCTAssertEqual(secondSession.phase, .exited)
    }
}
