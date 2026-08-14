import Foundation

enum LauncherItemKind: String, Equatable {
    case application = "Application"
    case systemSetting = "System Settings"
    case launcherSetting = "Launcher"
    case calculator = "Calculator"
    case scriptCommand = "Script Command"
    case runningShell = "Running Shell"
    case file = "File"
    case directory = "Folder"

    var symbolName: String {
        switch self {
        case .application: "app"
        case .systemSetting: "gearshape.fill"
        case .launcherSetting: "slider.horizontal.3"
        case .calculator: "equal"
        case .scriptCommand: "apple.terminal"
        case .runningShell: "apple.terminal.fill"
        case .file: "doc"
        case .directory: "folder"
        }
    }
}

enum LauncherDestination: Equatable {
    case url(URL)
    case launcherSettings
    case copyText(String)
    case script(ScriptCommand)
    case shellSession(ShellSessionID)
    case createScript
    case browseDirectory(URL)
}

struct LauncherItem: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let kind: LauncherItemKind
    let destination: LauncherDestination
    let keywords: String
    var detail: String? = nil

    var fileURL: URL? {
        switch destination {
        case let .url(url) where url.isFileURL: url
        case let .script(command): command.url
        case let .browseDirectory(url): url
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
