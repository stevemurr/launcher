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
}
