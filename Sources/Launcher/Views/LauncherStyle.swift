import CoreGraphics
import Foundation

/// Fixed geometry for the launcher panel. The window has two widths: compact,
/// and expanded while the ⌘P output pane is open. `LauncherLayoutTests` pins
/// these values and the drawer invariant.
enum LauncherStyle {
    static let panelWidth: CGFloat = 774
    static let expandedPanelWidth: CGFloat = 990
    static let panelHeight: CGFloat = 512

    /// The results region shrinks as the window grows, so the pane costs less
    /// screen than its own width: 526 + 464 == 990.
    static let drawerResultsWidth: CGFloat = 526
    static let outputPaneWidth: CGFloat = 464
    static let drawerAnimationDuration: TimeInterval = 0.18

    static let headerHeight: CGFloat = 59
    static let footerHeight: CGFloat = 39
    static let paneHeaderHeight: CGFloat = 32
    static let panelCornerRadius: CGFloat = 16
    static let terminalSideBorderWidth: CGFloat = 3

    // MARK: - Settings screen

    /// Settings rows have to earn their height: the panel is fixed, so rows
    /// that grow push the header and footer off both ends of it.
    static let settingsRowHeight: CGFloat = 56
    static let settingsShortcutRowHeight: CGFloat = 32
    static let settingsContentPadding: CGFloat = 8

    /// What the settings body gets once the header, the footer, and the
    /// hairline above each have taken their share. `LauncherLayoutTests`
    /// measures the real layout against this.
    static var settingsContentHeight: CGFloat {
        panelHeight - headerHeight - footerHeight - 2
    }
}
