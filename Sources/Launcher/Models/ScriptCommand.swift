import Foundation

enum ScriptMode: String, Equatable {
    case fullOutput
    case compact
    case silent
    case inline
}

struct ScriptArgument: Equatable {
    let placeholder: String
    let optional: Bool
}

struct ScriptCommand: Identifiable, Equatable {
    let id: String
    let url: URL
    let title: String
    let mode: ScriptMode
    let packageName: String?
    let description: String?
    let needsConfirmation: Bool
    let arguments: [ScriptArgument]
}
