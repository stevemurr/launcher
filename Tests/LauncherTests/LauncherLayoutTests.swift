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
        let model = LauncherModel(settings: settings, isUITesting: true)
        model.query = ">"
        XCTAssertTrue(model.isShellMode)
        XCTAssertEqual(model.query, "", "the trigger is not visible shell input")

        let hosting = NSHostingView(rootView: LauncherRootView(model: model))
        hosting.layoutSubtreeIfNeeded()

        XCTAssertEqual(hosting.fittingSize.width, LauncherStyle.expandedPanelWidth)
        XCTAssertEqual(hosting.fittingSize.height, LauncherStyle.panelHeight)
    }

    @MainActor
    func testShellCompletionPaletteStaysCompactAndCapsItsVisibleRows() {
        let shortPalette = NSHostingView(
            rootView: ShellCompletionPalette(
                candidates: ["git checkout", "git cherry-pick"],
                selectedIndex: 0,
                onAccept: { _ in }
            )
        )
        let longPalette = NSHostingView(
            rootView: ShellCompletionPalette(
                candidates: (0..<20).map { "candidate-\($0)" },
                selectedIndex: 12,
                onAccept: { _ in }
            )
        )
        shortPalette.layoutSubtreeIfNeeded()
        longPalette.layoutSubtreeIfNeeded()

        XCTAssertEqual(shortPalette.fittingSize.width, 560)
        XCTAssertEqual(shortPalette.fittingSize.height, 74)
        XCTAssertEqual(longPalette.fittingSize.width, 560)
        XCTAssertEqual(longPalette.fittingSize.height, 202)
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
