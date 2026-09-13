import SwiftUI
import XCTest
@testable import Launcher

/// The panel is borderless and fixed-size, so its geometry is a design decision
/// rather than something layout can recover from. Pin it.
final class LauncherLayoutTests: XCTestCase {
    func testApprovedPanelGeometry() {
        XCTAssertEqual(LauncherStyle.panelWidth, 774)
        XCTAssertEqual(LauncherStyle.expandedPanelWidth, 990)
        XCTAssertEqual(LauncherStyle.panelHeight, 512)
        XCTAssertEqual(LauncherStyle.drawerResultsWidth, 526)
        XCTAssertEqual(LauncherStyle.outputPaneWidth, 464)
        XCTAssertEqual(LauncherStyle.terminalSideBorderWidth, 3)
    }

    /// With the pane open the window is exactly the two regions side by side.
    func testDrawerRegionsFillTheExpandedPanel() {
        XCTAssertEqual(
            LauncherStyle.drawerResultsWidth + LauncherStyle.outputPaneWidth,
            LauncherStyle.expandedPanelWidth
        )
    }

    /// Shell mode borrows the drawer's expanded window size, but replaces the
    /// split results/output layout with one console spanning the whole body.
    @MainActor
    func testShellModeUsesTheExpandedPanelWidthBeforeACommandRuns() {
        let suite = "LauncherLayoutTests-Shell-\(UUID().uuidString)"
        let settings = LauncherSettings(defaults: UserDefaults(suiteName: suite)!)
        let terminalStore = LauncherTerminalStore()
        let model = LauncherModel(
            settings: settings,
            isUITesting: true,
            usesNativeTerminalSessions: true
        )
        model.onCreateNativeTerminalSession = { launchInput in
            let summary = terminalStore.createSession()
            if !launchInput.isEmpty {
                terminalStore.session(for: summary.id)?.queueInput(launchInput)
            }
            return summary
        }
        model.onSelectNativeTerminalSession = { terminalStore.selectSession($0) }
        model.onCloseNativeTerminalSession = { terminalStore.closeSession($0) }
        model.query = ">"
        XCTAssertTrue(model.isShellMode)
        XCTAssertEqual(model.query, "", "the trigger is not visible shell input")

        let hosting = NSHostingView(
            rootView: LauncherRootView(model: model, terminalStore: terminalStore)
                .transaction { $0.disablesAnimations = true }
        )
        hosting.layoutSubtreeIfNeeded()

        XCTAssertEqual(hosting.fittingSize.width, LauncherStyle.expandedPanelWidth)
        XCTAssertEqual(hosting.fittingSize.height, LauncherStyle.panelHeight)

        let sessionID = model.selectedShellSessionID
        let session = terminalStore.selectedSession
        XCTAssertTrue(model.setTerminalSize(.larger))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(hosting.fittingSize.width, 1237.5, accuracy: 0.5)
        XCTAssertEqual(hosting.fittingSize.height, 640)
        XCTAssertTrue(model.setTerminalSize(.largest))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(hosting.fittingSize.width, 1485)
        XCTAssertEqual(hosting.fittingSize.height, 768)
        XCTAssertEqual(model.selectedShellSessionID, sessionID)
        XCTAssertTrue(terminalStore.selectedSession === session)

        XCTAssertTrue(model.setTerminalSize(.standard))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(hosting.fittingSize.width, 990)
        XCTAssertEqual(hosting.fittingSize.height, 512)

        model.setTerminalSize(.larger)
        model.leaveShellMode()
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(hosting.fittingSize.width, LauncherStyle.panelWidth)
        XCTAssertEqual(hosting.fittingSize.height, LauncherStyle.panelHeight)
        XCTAssertFalse(model.setTerminalSize(.larger), "size shortcuts belong only to a visible terminal")
        model.resumeShellSession(id: sessionID!)
        XCTAssertEqual(model.terminalSize, .larger)
        XCTAssertEqual(model.terminalPanelSize, LauncherTerminalSize.larger.size)
        model.prepareForDismissal()
        model.prepareForPresentation()
        XCTAssertEqual(model.terminalSize, .larger)
        XCTAssertEqual(model.terminalPanelSize, LauncherTerminalSize.larger.size)
        terminalStore.terminateAll()
    }

    func testTerminalSizePreferenceSurvivesSettingsAndModelRecreation() {
        let suite = "LauncherLayoutTests-SizePreference-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = LauncherSettings(defaults: defaults)
        XCTAssertEqual(settings.terminalSize, .standard)

        settings.save(terminalSize: .larger)
        let restored = LauncherSettings(defaults: UserDefaults(suiteName: suite)!)
        let model = LauncherModel(settings: restored, isUITesting: true, usesNativeTerminalSessions: true)
        XCTAssertEqual(model.terminalSize, .larger)
        XCTAssertEqual(model.terminalPanelSize, LauncherTerminalSize.larger.size)
        settings.save(terminalSize: .largest)
        XCTAssertEqual(LauncherSettings(defaults: defaults).terminalSize, .largest)
        settings.save(terminalSize: .larger)

        model.updateTerminalPanelSize(CGSize(width: 1100, height: 568.89))
        XCTAssertEqual(LauncherSettings(defaults: defaults).terminalSize, .larger,
                       "screen constraints must not overwrite the saved preference")

        restored.save(terminalSize: .standard)
        XCTAssertEqual(LauncherSettings(defaults: defaults).terminalSize, .standard)
        defaults.set("invalid-size", forKey: "launcher.terminalSize")
        XCTAssertEqual(LauncherSettings(defaults: defaults).terminalSize, .standard)
    }

    func testLargerTerminalPreservesCenterAndAspectRatio() {
        let standard = NSRect(x: 200, y: 150, width: 990, height: 512)
        let frame = LauncherWindowLifecycle.terminalFrame(standard: standard, size: .larger, visibleFrame: screen)
        XCTAssertEqual(frame.width, standard.width * 1.25)
        XCTAssertEqual(frame.height, standard.height * 1.25)
        XCTAssertEqual(frame.midX, standard.midX)
        XCTAssertEqual(frame.midY, standard.midY)
        let restored = LauncherWindowLifecycle.terminalFrame(standard: standard, size: .standard, visibleFrame: screen)
        XCTAssertEqual(restored, standard)
    }

    func testLargerTerminalFitsSmallOffsetScreenWithoutChangingAspectRatio() {
        let smallScreen = NSRect(x: -1200, y: 40, width: 1100, height: 600)
        let standard = NSRect(x: -1090, y: 110, width: 990, height: 512)
        let frame = LauncherWindowLifecycle.terminalFrame(standard: standard, size: .larger, visibleFrame: smallScreen)
        XCTAssertTrue(smallScreen.contains(frame))
        XCTAssertEqual(frame.width / frame.height, standard.width / standard.height, accuracy: 0.0001)
        XCTAssertGreaterThan(frame.width, standard.width)
    }

    @MainActor
    func testTerminalSizeShortcutsAreConsumedOnlyWhenAccepted() throws {
        let panel = LauncherPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        var selections: [LauncherTerminalSize] = []
        var acceptsResize = true
        panel.onTerminalSize = { size in
            guard acceptsResize else { return false }
            selections.append(size)
            return true
        }
        func event(_ key: String, modifiers: NSEvent.ModifierFlags = .command) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: 0, context: nil, characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: key == "1" ? 18 : 19
            ))
        }
        XCTAssertTrue(panel.performKeyEquivalent(with: try event("2")))
        XCTAssertTrue(panel.performKeyEquivalent(with: try event("1", modifiers: [.command, .capsLock])))
        XCTAssertTrue(panel.performKeyEquivalent(with: try event("3")))
        XCTAssertEqual(selections, [.larger, .standard, .largest])
        XCTAssertFalse(panel.performKeyEquivalent(with: try event("2", modifiers: [.command, .shift])))
        acceptsResize = false
        XCTAssertFalse(panel.performKeyEquivalent(with: try event("2")))
        XCTAssertEqual(selections.count, 3)
    }

    @MainActor
    func testCommandPRemainsAvailableOutsideTerminalMode() throws {
        let panel = LauncherPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "p", charactersIgnoringModifiers: "p",
            isARepeat: false, keyCode: 35
        ))
        panel.onPinTerminal = { false }
        XCTAssertFalse(panel.performKeyEquivalent(with: event))
        panel.onPinTerminal = { true }
        XCTAssertTrue(panel.performKeyEquivalent(with: event))
    }

    @MainActor
    func testPinnedResultFocusDoesNotSelectOrRemountTheSession() {
        let defaults = UserDefaults(suiteName: "LauncherPinnedRouting-\(UUID().uuidString)")!
        let model = LauncherModel(settings: LauncherSettings(defaults: defaults), isUITesting: true,
                                  usesNativeTerminalSessions: true)
        let id = ShellSessionID()
        var focused: [ShellSessionID] = []
        model.onFocusPinnedTerminalSession = { focused.append($0); return true }
        model.onSelectNativeTerminalSession = { _ in XCTFail("pinned surfaces must stay in their window"); return false }
        model.resumeShellSession(id: id)
        XCTAssertEqual(focused, [id])
        XCTAssertFalse(model.isShellMode)
        XCTAssertNil(model.selectedShellSessionID)
        XCTAssertFalse(model.pinTerminal())
    }

    /// The results region shrinks as the window grows, so the pane costs the
    /// screen less than its own width.
    func testPaneCostsLessScreenThanItsWidth() {
        let growth = LauncherStyle.expandedPanelWidth - LauncherStyle.panelWidth
        XCTAssertEqual(growth, 216)
        XCTAssertLessThan(growth, LauncherStyle.outputPaneWidth)
        XCTAssertEqual(
            LauncherStyle.panelWidth - LauncherStyle.drawerResultsWidth,
            LauncherStyle.outputPaneWidth - growth
        )
    }

    // MARK: - Settings screen

    /// Settings is the tallest screen the fixed panel has to hold, and nothing
    /// warns you when it stops fitting: SwiftUI centers the overflow, so a
    /// too-tall body clips the header off the top and the footer off the
    /// bottom. Measure the real layout rather than trusting the arithmetic.
    @MainActor
    func testSettingsScreenFitsThePanelWithoutScrolling() {
        let settings = LauncherSettings(defaults: UserDefaults(suiteName: "LauncherLayoutTests")!)
        let model = LauncherModel(settings: settings, isUITesting: true)
        let hosting = NSHostingView(rootView: LauncherSettingsView(model: model, settings: settings))
        hosting.frame = NSRect(
            x: 0,
            y: 0,
            width: LauncherStyle.panelWidth,
            height: LauncherStyle.panelHeight
        )
        hosting.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(
            hosting.fittingSize.height,
            LauncherStyle.panelHeight,
            "settings wants \(hosting.fittingSize.height)pt in a \(LauncherStyle.panelHeight)pt panel; "
                + "trim a row or the panel will clip its own header and footer"
        )
    }

    /// The body is what absorbs the remainder, so a row tall enough to fill the
    /// panel on its own would leave nothing for the chrome.
    func testSettingsBodyLeavesRoomForTheChrome() {
        XCTAssertEqual(
            LauncherStyle.settingsContentHeight,
            LauncherStyle.panelHeight - LauncherStyle.headerHeight - LauncherStyle.footerHeight - 2
        )
        XCTAssertGreaterThan(LauncherStyle.settingsContentHeight, LauncherStyle.settingsRowHeight * 3)
    }

    // MARK: - Drawer frame math

    /// A 1440-wide display with a menu bar, the panel centered on it.
    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 875)
    private var centered: NSRect {
        NSRect(x: 333, y: 181, width: LauncherStyle.panelWidth, height: LauncherStyle.panelHeight)
    }

    func testExpandingKeepsTheLeftEdgeAndHeight() {
        let expanded = LauncherWindowLifecycle.panelFrame(
            current: centered,
            width: LauncherStyle.expandedPanelWidth,
            preferredOrigin: centered.origin,
            visibleFrame: screen
        )

        XCTAssertEqual(expanded.origin.x, centered.origin.x, "the left edge must not move")
        XCTAssertEqual(expanded.origin.y, centered.origin.y)
        XCTAssertEqual(expanded.width, LauncherStyle.expandedPanelWidth)
        XCTAssertEqual(expanded.height, LauncherStyle.panelHeight)
    }

    func testExpandingNearTheRightEdgeShiftsLeftJustEnough() {
        // Compact panel flush against the right edge of the display.
        var atEdge = centered
        atEdge.origin.x = screen.maxX - LauncherStyle.panelWidth

        let expanded = LauncherWindowLifecycle.panelFrame(
            current: atEdge,
            width: LauncherStyle.expandedPanelWidth,
            preferredOrigin: atEdge.origin,
            visibleFrame: screen
        )

        XCTAssertEqual(expanded.maxX, screen.maxX, "the panel must stay on screen")
        XCTAssertEqual(expanded.origin.x, screen.maxX - LauncherStyle.expandedPanelWidth)
        XCTAssertGreaterThanOrEqual(expanded.origin.x, screen.minX)
    }

    /// The remembered compact origin undoes an edge-induced shift on collapse.
    func testCollapsingRestoresTheRememberedOrigin() {
        var atEdge = centered
        atEdge.origin.x = screen.maxX - LauncherStyle.panelWidth
        let rememberedOrigin = atEdge.origin

        let expanded = LauncherWindowLifecycle.panelFrame(
            current: atEdge,
            width: LauncherStyle.expandedPanelWidth,
            preferredOrigin: rememberedOrigin,
            visibleFrame: screen
        )
        XCTAssertNotEqual(expanded.origin.x, rememberedOrigin.x, "this case must actually shift")

        let collapsed = LauncherWindowLifecycle.panelFrame(
            current: expanded,
            width: LauncherStyle.panelWidth,
            preferredOrigin: rememberedOrigin,
            visibleFrame: screen
        )
        XCTAssertEqual(collapsed.origin, rememberedOrigin)
        XCTAssertEqual(collapsed.width, LauncherStyle.panelWidth)
    }

    /// A panel wider than the display clamps to the left edge rather than
    /// sliding off the far side.
    func testPanelWiderThanScreenClampsToLeftEdge() {
        let narrow = NSRect(x: 0, y: 0, width: 800, height: 600)
        let frame = LauncherWindowLifecycle.panelFrame(
            current: centered,
            width: LauncherStyle.expandedPanelWidth,
            preferredOrigin: centered.origin,
            visibleFrame: narrow
        )

        XCTAssertEqual(frame.origin.x, narrow.minX)
    }

    func testUnknownScreenLeavesTheOriginAlone() {
        let frame = LauncherWindowLifecycle.panelFrame(
            current: centered,
            width: LauncherStyle.expandedPanelWidth,
            preferredOrigin: nil,
            visibleFrame: nil
        )

        XCTAssertEqual(frame.origin, centered.origin)
        XCTAssertEqual(frame.width, LauncherStyle.expandedPanelWidth)
    }
}
