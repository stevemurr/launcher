import Foundation

/// How a script run presents itself. `silent` is the only mode that changes
/// behavior — it dismisses the launcher and never offers output. Every other
/// value, including the legacy Raycast modes (fullOutput/compact/inline) and
/// anything unrecognized, is `normal`: a footer chip plus the ⌘P output pane.
enum ScriptMode: String, Equatable {
    case normal
    case silent

    init(metadataValue: String?) {
        self = metadataValue?.lowercased() == ScriptMode.silent.rawValue ? .silent : .normal
    }

    /// Written back into script headers. `normal` serializes as the legacy
    /// `compact` so files the launcher creates stay valid Raycast script
    /// commands (see ScriptMetadataParser's drop-in compatibility note).
    var metadataValue: String {
        switch self {
        case .normal: "compact"
        case .silent: "silent"
        }
    }
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
