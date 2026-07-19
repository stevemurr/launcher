import Foundation

enum LauncherItemKind: String, Equatable {
    case application = "Application"
    case systemSetting = "System Settings"
    case launcherSetting = "Launcher"
    case calculator = "Calculator"
    case scriptCommand = "Script Command"

    var symbolName: String {
        switch self {
        case .application: "app"
        case .systemSetting: "gearshape.fill"
        case .launcherSetting: "slider.horizontal.3"
        case .calculator: "equal"
        case .scriptCommand: "apple.terminal"
        }
    }
}

enum LauncherDestination: Equatable {
    case url(URL)
    case launcherSettings
    case copyText(String)
    case script(ScriptCommand)
    case createScript
}

struct LauncherItem: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let kind: LauncherItemKind
    let destination: LauncherDestination
    let keywords: String

    var fileURL: URL? {
        switch destination {
        case let .url(url) where url.isFileURL: url
        case let .script(command): command.url
        default: nil
        }
    }
}

struct ApplicationRecord: Equatable, Sendable {
    let id: String
    let name: String
    let url: URL
    let keywords: String
}
