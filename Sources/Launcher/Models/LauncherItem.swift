import Foundation

enum LauncherItemKind: String, Equatable {
    case application = "Application"
    case systemSetting = "System Settings"
    case launcherSetting = "Launcher"
    case calculator = "Calculator"

    var symbolName: String {
        switch self {
        case .application: "app"
        case .systemSetting: "gearshape.fill"
        case .launcherSetting: "slider.horizontal.3"
        case .calculator: "equal"
        }
    }
}

enum LauncherDestination: Equatable {
    case url(URL)
    case launcherSettings
    case copyText(String)
}

struct LauncherItem: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let kind: LauncherItemKind
    let destination: LauncherDestination
    let keywords: String

    var fileURL: URL? {
        guard case let .url(url) = destination, url.isFileURL else { return nil }
        return url
    }
}

struct ApplicationRecord: Equatable, Sendable {
    let id: String
    let name: String
    let url: URL
    let keywords: String
}
