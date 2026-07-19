import Foundation

enum ScriptTemplate: String, CaseIterable, Identifiable {
    case bash
    case zsh
    case python

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bash: "Bash"
        case .zsh: "Zsh"
        case .python: "Python"
        }
    }

    var fileExtension: String {
        switch self {
        case .bash, .zsh: "sh"
        case .python: "py"
        }
    }

    var shebang: String {
        switch self {
        case .bash: "#!/bin/bash"
        case .zsh: "#!/bin/zsh"
        case .python: "#!/usr/bin/env python3"
        }
    }

    var commentPrefix: String { "#" }

    var bodyPlaceholder: String {
        switch self {
        case .bash, .zsh: "echo \"Hello from Launcher!\""
        case .python: "print(\"Hello from Launcher!\")"
        }
    }
}

struct ScriptDraft {
    var template: ScriptTemplate = .bash
    var mode: ScriptMode = .compact
    var title = ""
    var description = ""
    var packageName = ""
    var needsConfirmation = false
    var argumentPlaceholders: [String] = []

    func fileContents() -> String {
        let comment = template.commentPrefix
        var lines = [
            template.shebang,
            "",
            "\(comment) Required parameters:",
            "\(comment) @raycast.schemaVersion 1",
            "\(comment) @raycast.title \(title)",
            "\(comment) @raycast.mode \(mode.rawValue)",
            "",
            "\(comment) Optional parameters:"
        ]
        let trimmedPackage = packageName.trimmingCharacters(in: .whitespaces)
        if !trimmedPackage.isEmpty {
            lines.append("\(comment) @raycast.packageName \(trimmedPackage)")
        }
        let trimmedDescription = description.trimmingCharacters(in: .whitespaces)
        if !trimmedDescription.isEmpty {
            lines.append("\(comment) @raycast.description \(trimmedDescription)")
        }
        if needsConfirmation {
            lines.append("\(comment) @raycast.needsConfirmation true")
        }
        for (index, placeholder) in argumentPlaceholders.prefix(3).enumerated() {
            let trimmed = placeholder.trimmingCharacters(in: .whitespaces)
            let value = trimmed.isEmpty ? "Argument \(index + 1)" : trimmed
            lines.append(
                "\(comment) @raycast.argument\(index + 1) { \"type\": \"text\", \"placeholder\": \"\(value)\" }"
            )
        }
        lines.append("")
        lines.append(template.bodyPlaceholder)
        lines.append("")
        return lines.joined(separator: "\n")
    }
}

enum ScriptCommandCreator {
    static func create(draft: ScriptDraft, in directory: URL, fileManager: FileManager = .default) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let slug = slugify(draft.title)
        var url = directory.appendingPathComponent("\(slug).\(draft.template.fileExtension)")
        var counter = 2
        while fileManager.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(slug)-\(counter).\(draft.template.fileExtension)")
            counter += 1
        }

        try draft.fileContents().write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private static func slugify(_ title: String) -> String {
        let lowered = title.lowercased()
        var slug = ""
        var previousWasDash = true
        for character in lowered {
            if character.isLetter || character.isNumber {
                slug.append(character)
                previousWasDash = false
            } else if !previousWasDash {
                slug.append("-")
                previousWasDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "script" : slug
    }
}
