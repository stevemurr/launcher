import CoreGraphics
import Foundation

enum LauncherTerminalSize: String {
    case standard
    case larger
    case largest

    static func shortcut(_ key: String) -> Self? {
        switch key {
        case "1": .standard
        case "2": .larger
        case "3": .largest
        default: nil
        }
    }

    var next: Self {
        switch self {
        case .standard: .larger
        case .larger: .largest
        case .largest: .standard
        }
    }

    var shortcutLabel: String {
        switch self {
        case .standard: "Standard  ⌘1"
        case .larger: "Larger  ⌘2"
        case .largest: "Largest  ⌘3"
        }
    }

    var size: CGSize {
        let scale: CGFloat = switch self {
        case .standard: 1
        case .larger: 1.25
        case .largest: 1.5
        }
        return CGSize(width: LauncherStyle.expandedPanelWidth * scale,
                      height: LauncherStyle.panelHeight * scale)
    }
}

/// Base geometry for the launcher panel. Search uses compact and drawer
/// widths; terminals start at drawer size and can scale up proportionally.
/// `LauncherLayoutTests` pins these values and the drawer invariant.
enum LauncherStyle {
    static let panelWidth: CGFloat = 774
    static let expandedPanelWidth: CGFloat = 990
    static let panelHeight: CGFloat = 512

    /// The results region shrinks as the window grows, so the pane costs less
    /// screen than its own width: 526 + 464 == 990.
    static let drawerResultsWidth: CGFloat = 526
    static let outputPaneWidth: CGFloat = 464
    static let drawerAnimationDuration: TimeInterval = 0.18
    static let terminalResizeAnimationDuration: TimeInterval = 0.24

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
