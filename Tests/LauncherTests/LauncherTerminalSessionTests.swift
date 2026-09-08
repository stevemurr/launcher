import AppKit
import XCTest
@testable import Launcher

final class LauncherTerminalSessionTests: XCTestCase {
    func testBaseConfigurationRendersLauncherPolicyAndReservesCommandK() {
        let renderedLines = LauncherTerminalConfiguration
            .base(shell: "/bin/test-shell")
            .rendered
            .split(separator: "\n")
            .map(String.init)

        XCTAssertEqual(
            renderedLines,
            [
                "command = direct:/bin/test-shell -l",
                "term = xterm-256color",
                "shell-integration = detect",
                "copy-on-select = false",
                "clipboard-read = deny",
                "clipboard-write = deny",
                "clipboard-paste-protection = true",
                "scrollbar = never",
                "notify-on-command-finish = never",
                "keybind = super+k=unbind",
            ]
        )
    }

    func testLoginShellAcceptsValidatedExecutableAndFallsBackForInvalidCandidates() {
        XCTAssertEqual(
            LauncherTerminalConfiguration.loginShell(environment: ["SHELL": "/bin/sh"]),
            "/bin/sh"
        )
        XCTAssertEqual(
            LauncherTerminalConfiguration.loginShell(environment: [:]),
            "/bin/zsh"
        )

        let invalidCandidates = [
            "bin/sh",
            "/bin/ sh",
            "/bin/sh\n",
            "/private/tmp/launcher-terminal-missing-\(UUID().uuidString)",
        ]
        for candidate in invalidCandidates {
            XCTAssertEqual(
                LauncherTerminalConfiguration.loginShell(environment: ["SHELL": candidate]),
                "/bin/zsh",
                "candidate should not be accepted: \(candidate.debugDescription)"
            )
        }
    }

    func testHostNoColorPolicyIsRemovedBeforeTerminalStartup() {
        let original = getenv("NO_COLOR").map { String(cString: $0) }
        defer {
            if let original {
                setenv("NO_COLOR", original, 1)
            } else {
                unsetenv("NO_COLOR")
            }
        }

        setenv("NO_COLOR", "1", 1)
        LauncherTerminalConfiguration.sanitizeProcessEnvironment()

        XCTAssertNil(getenv("NO_COLOR"))
    }

    @MainActor
    func testTerminalViewIdentityIsRetainedWithoutMountingAWindow() {
        let session = LauncherTerminalSession()

        let first = session.makeTerminalView()
        let second = session.makeTerminalView()

        XCTAssertTrue(first === second)
        XCTAssertNil(first.window)
        session.terminate()
    }

    @MainActor
    func testTerminateIsIdempotentAndLeavesSessionExited() {
        let session = LauncherTerminalSession()
        _ = session.makeTerminalView()

        session.terminate()
        XCTAssertEqual(session.phase, .exited)

        session.restart()
        XCTAssertEqual(session.phase, .exited, "explicit teardown cannot resurrect a shell")

        session.terminate()
        session.terminalDidClose(processAlive: false)
        XCTAssertEqual(session.phase, .exited)
    }

    @MainActor
    func testFocusRefusesHiddenAndTerminatedSession() {
        let session = LauncherTerminalSession()
        let terminalView = session.makeTerminalView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = terminalView

        session.setVisible(false)
        XCTAssertFalse(session.focus())

        session.setVisible(true)
        XCTAssertTrue(session.focus())

        session.terminate()
        XCTAssertFalse(session.focus())
    }

    func testPastedShellDraftIsDeliveredExactlyOnceToNativeCreationCallback() {
        let model = makeModel(usesNativeTerminalSessions: true)
        let created = terminalSummary(displayName: "Shell 1")
        var launchInputs: [String] = []
        configureNativeCallbacks(
            on: model,
            create: { launchInput in
                launchInputs.append(launchInput)
                return created
            }
        )

        model.query = "> printf launcher-native"

        XCTAssertTrue(model.isShellMode)
        XCTAssertEqual(launchInputs, ["printf launcher-native"])
        XCTAssertEqual(model.nativeTerminalSessions, [created])
        XCTAssertEqual(model.selectedShellSessionID, created.id)
        XCTAssertEqual(model.query, "")
    }

    func testPrepareForPresentationPreservesActiveNativeShellMode() {
        let model = makeModel(usesNativeTerminalSessions: true)
        let created = terminalSummary(displayName: "Shell 1")
        configureNativeCallbacks(on: model, create: { _ in created })
        model.query = ">"
        let focusToken = model.focusToken

        model.prepareForPresentation(screen: .search)

        XCTAssertTrue(model.isShellMode)
        XCTAssertEqual(model.panelPresentation, .shellConsole)
        XCTAssertTrue(model.isPanelExpanded)
        XCTAssertEqual(model.nativeTerminalSessions, [created])
        XCTAssertEqual(model.focusToken, focusToken)
    }

    func testLeaveShellModeReturnsToCompactLauncherAndRequestsSearchFocus() {
        let model = makeModel(usesNativeTerminalSessions: true)
        let created = terminalSummary(displayName: "Shell 1")
        configureNativeCallbacks(on: model, create: { _ in created })
        model.query = ">"
        let focusToken = model.focusToken

        model.leaveShellMode()

        XCTAssertFalse(model.isShellMode)
        XCTAssertEqual(model.panelPresentation, .compact)
        XCTAssertEqual(model.focusTarget, .search)
        XCTAssertEqual(model.focusToken, focusToken + 1)
        XCTAssertEqual(model.query, "")
    }

    func testPrepareForPresentationExitsLegacyShellMode() {
        let model = makeModel()
        model.query = "> legacy draft"
        XCTAssertTrue(model.isShellMode)

        model.prepareForPresentation(screen: .search)

        XCTAssertFalse(model.isShellMode)
        XCTAssertNil(model.selectedShellSessionID)
        XCTAssertEqual(model.panelPresentation, .compact)
        XCTAssertEqual(model.focusTarget, .search)
        XCTAssertEqual(model.query, "")
    }

    func testMissingNativeCreationSeamStaysInCompactLauncherWithoutASummary() {
        let model = makeModel(usesNativeTerminalSessions: true)

        model.query = "> unavailable"

        XCTAssertFalse(model.isShellMode)
        XCTAssertNil(model.selectedShellSessionID)
        XCTAssertTrue(model.nativeTerminalSessions.isEmpty)
        XCTAssertEqual(model.panelPresentation, .compact)
        XCTAssertEqual(model.query, "")
    }

    func testRejectedActiveNativeClosePreservesShellSelectionAndSummary() {
        let model = makeModel(usesNativeTerminalSessions: true)
        let created = terminalSummary(displayName: "Shell 1", phase: .ready)
        var closeRequests: [ShellSessionID] = []
        var deselectionCount = 0
        configureNativeCallbacks(
            on: model,
            create: { _ in created },
            close: { id in
                closeRequests.append(id)
                return false
            }
        )
        model.onDeselectNativeTerminalSession = { deselectionCount += 1 }
        model.query = ">"

        model.closeShellSession(id: created.id)

        XCTAssertEqual(closeRequests, [created.id])
        XCTAssertEqual(deselectionCount, 0)
        XCTAssertTrue(model.isShellMode)
        XCTAssertEqual(model.selectedShellSessionID, created.id)
        XCTAssertEqual(model.nativeTerminalSessions, [created])
        XCTAssertEqual(model.panelPresentation, .shellConsole)
    }

    func testRejectedAndMissingNativeResumeDoNotEnterShellMode() {
        let model = makeModel(usesNativeTerminalSessions: true)
        let created = terminalSummary(displayName: "Shell 1", phase: .ready)
        var selectionRequests: [ShellSessionID] = []
        configureNativeCallbacks(
            on: model,
            create: { _ in created },
            select: { id in
                selectionRequests.append(id)
                return false
            }
        )
        model.query = ">"
        model.leaveShellMode()

        model.resumeShellSession(id: created.id)

        XCTAssertEqual(selectionRequests, [created.id])
        XCTAssertFalse(model.isShellMode)
        XCTAssertNil(model.selectedShellSessionID)
        XCTAssertEqual(model.nativeTerminalSessions, [created])
        XCTAssertEqual(model.panelPresentation, .compact)

        model.onSelectNativeTerminalSession = nil
        model.resumeShellSession(id: created.id)

        XCTAssertEqual(selectionRequests, [created.id])
        XCTAssertFalse(model.isShellMode)
        XCTAssertNil(model.selectedShellSessionID)
        XCTAssertEqual(model.nativeTerminalSessions, [created])
        XCTAssertEqual(model.panelPresentation, .compact)
    }

    func testAcceptedLateNativeTailForwardsExactlyOnceAndClearsQuery() {
        let model = makeModel(usesNativeTerminalSessions: true)
        let created = terminalSummary(displayName: "Shell 1")
        var forwarded: [(ShellSessionID, String)] = []
        configureNativeCallbacks(on: model, create: { _ in created })
        model.onSendNativeTerminalInput = { id, input in
            forwarded.append((id, input))
            return true
        }
        model.query = ">"

        model.query = " printf late-tail"

        XCTAssertEqual(forwarded.count, 1)
        XCTAssertEqual(forwarded.first?.0, created.id)
        XCTAssertEqual(forwarded.first?.1, "printf late-tail")
        XCTAssertTrue(model.isShellMode)
        XCTAssertEqual(model.selectedShellSessionID, created.id)
        XCTAssertEqual(model.query, "")
    }

    func testRejectedLateNativeTailReturnsToLauncherWithVisibleQuery() {
        let model = makeModel(usesNativeTerminalSessions: true)
        let created = terminalSummary(displayName: "Shell 1")
        var forwarded: [(ShellSessionID, String)] = []
        configureNativeCallbacks(on: model, create: { _ in created })
        model.onSendNativeTerminalInput = { id, input in
            forwarded.append((id, input))
            return false
        }
        model.query = ">"

        model.query = " rejected late-tail"

        XCTAssertEqual(forwarded.count, 1)
        XCTAssertEqual(forwarded.first?.0, created.id)
        XCTAssertEqual(forwarded.first?.1, "rejected late-tail")
        XCTAssertFalse(model.isShellMode)
        XCTAssertNil(model.selectedShellSessionID)
        XCTAssertEqual(model.nativeTerminalSessions, [created])
        XCTAssertEqual(model.panelPresentation, .compact)
        XCTAssertEqual(model.query, "rejected late-tail")
        XCTAssertEqual(model.focusTarget, .search)
    }

    func testNativeShellTriggersCreateRowsNewestFirstAndResumeExactIdentity() throws {
        let model = makeModel(usesNativeTerminalSessions: true)
        let first = terminalSummary(displayName: "Shell 1")
        let second = terminalSummary(displayName: "Shell 2")
        var summariesToCreate = [first, second]
        var launchInputs: [String] = []
        var selected: [ShellSessionID] = []
        configureNativeCallbacks(
            on: model,
            create: { launchInput in
                launchInputs.append(launchInput)
                return summariesToCreate.removeFirst()
            },
            select: { id in
                selected.append(id)
                return [first.id, second.id].contains(id)
            }
        )

        model.query = ">"
        let firstID = try XCTUnwrap(model.selectedShellSessionID)
        model.leaveShellMode()

        model.query = ">"
        let secondID = try XCTUnwrap(model.selectedShellSessionID)
        model.leaveShellMode()

        XCTAssertEqual(firstID, first.id)
        XCTAssertEqual(secondID, second.id)
        XCTAssertEqual(launchInputs, ["", ""])
        XCTAssertEqual(model.nativeTerminalSessions, [first, second])
        XCTAssertEqual(model.results.prefix(2).map(\.title), ["Shell 2", "Shell 1"])
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertEqual(model.selectedItem?.title, "Shell 2")
        XCTAssertEqual(
            model.results.prefix(2).map(\.destination),
            [.shellSession(secondID), .shellSession(firstID)]
        )

        model.resumeShellSession(id: firstID)
        XCTAssertTrue(model.isShellMode)
        XCTAssertEqual(model.selectedShellSessionID, firstID)
        XCTAssertEqual(selected, [firstID])
    }

    func testNativeShellSummariesRefreshRowsAndCloseOnlyRequestedSession() throws {
        let model = makeModel(usesNativeTerminalSessions: true)
        let firstCreated = terminalSummary(displayName: "Shell 1")
        let secondCreated = terminalSummary(displayName: "Shell 2")
        var summariesToCreate = [firstCreated, secondCreated]
        var authoritativeSummaries: [LauncherTerminalSummary] = []
        var closed: [ShellSessionID] = []
        configureNativeCallbacks(
            on: model,
            create: { _ in
                let summary = summariesToCreate.removeFirst()
                authoritativeSummaries.append(summary)
                return summary
            },
            select: { id in authoritativeSummaries.contains { $0.id == id } },
            close: { id in
                guard authoritativeSummaries.contains(where: { $0.id == id }) else {
                    return false
                }
                closed.append(id)
                authoritativeSummaries.removeAll { $0.id == id }
                model.updateNativeTerminalSessions(authoritativeSummaries)
                return true
            }
        )

        model.query = ">"
        let firstID = try XCTUnwrap(model.selectedShellSessionID)
        model.leaveShellMode()
        model.query = ">"
        let secondID = try XCTUnwrap(model.selectedShellSessionID)
        model.leaveShellMode()

        let firstSnapshot = [
            LauncherTerminalSummary(
                id: firstID,
                displayName: "Shell 1",
                phase: .ready,
                workingDirectory: "/tmp/first"
            ),
        ]
        authoritativeSummaries = firstSnapshot
        model.updateNativeTerminalSessions(firstSnapshot)
        XCTAssertEqual(model.nativeTerminalSessions, firstSnapshot, "store snapshots are authoritative")

        let refreshedSnapshot = [
            LauncherTerminalSummary(
                id: firstID,
                displayName: "Shell 1",
                phase: .ready,
                workingDirectory: "/tmp/first"
            ),
            LauncherTerminalSummary(
                id: secondID,
                displayName: "Shell 2",
                phase: .exited,
                workingDirectory: "/tmp/second"
            ),
        ]
        authoritativeSummaries = refreshedSnapshot
        model.updateNativeTerminalSessions(refreshedSnapshot)

        XCTAssertEqual(model.results[0].subtitle, "Exited in /tmp/second")
        XCTAssertEqual(model.results[1].subtitle, "Ready in /tmp/first")

        model.closeShellSession(id: firstID)

        XCTAssertEqual(closed, [firstID])
        XCTAssertEqual(model.nativeTerminalSessions, [refreshedSnapshot[1]])
        XCTAssertEqual(model.results.prefix(1).map(\.destination), [.shellSession(secondID)])
    }

    @MainActor
    func testPanelConsumesCommandKOnlyWhenReturnHandlerAcceptsIt() throws {
        let panel = LauncherPanel(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        var invocationCount = 0
        var acceptsReturn = true
        panel.onReturnToLauncher = {
            invocationCount += 1
            return acceptsReturn
        }

        XCTAssertTrue(panel.performKeyEquivalent(with: try commandKEvent()))
        XCTAssertEqual(invocationCount, 1)

        acceptsReturn = false
        XCTAssertFalse(panel.performKeyEquivalent(with: try commandKEvent()))
        XCTAssertEqual(invocationCount, 2)

        XCTAssertFalse(
            panel.performKeyEquivalent(with: try commandKEvent(modifiers: [.command, .shift]))
        )
        XCTAssertEqual(invocationCount, 2, "modified Command-K must remain available to responders")
    }

    private func configureNativeCallbacks(
        on model: LauncherModel,
        create: @escaping (String) -> LauncherTerminalSummary?,
        select: @escaping (ShellSessionID) -> Bool = { _ in true },
        close: @escaping (ShellSessionID) -> Bool = { _ in true }
    ) {
        model.onCreateNativeTerminalSession = create
        model.onSelectNativeTerminalSession = select
        model.onCloseNativeTerminalSession = close
    }

    private func terminalSummary(
        id: ShellSessionID = ShellSessionID(),
        displayName: String,
        phase: LauncherTerminalPhase = .idle,
        workingDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> LauncherTerminalSummary {
        LauncherTerminalSummary(
            id: id,
            displayName: displayName,
            phase: phase,
            workingDirectory: workingDirectory
        )
    }

    private func makeModel(usesNativeTerminalSessions: Bool = false) -> LauncherModel {
        let defaults = UserDefaults(
            suiteName: "LauncherTerminalSessionTests-\(UUID().uuidString)"
        )!
        return LauncherModel(
            settings: LauncherSettings(defaults: defaults),
            isUITesting: true,
            usesNativeTerminalSessions: usesNativeTerminalSessions
        )
    }

    private func commandKEvent(
        modifiers: NSEvent.ModifierFlags = [.command]
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "k",
                charactersIgnoringModifiers: "k",
                isARepeat: false,
                keyCode: 40
            )
        )
    }
}
