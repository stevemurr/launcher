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

/// Serializes an `@raycast.argumentN` metadata object, escaping the
/// placeholder so it survives JSONSerialization round-trips even when it
/// contains quotes or backslashes.
private func argumentMetadataJSON(placeholder: String) -> String {
    let object: [String: Any] = ["type": "text", "placeholder": placeholder]
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
       let json = String(data: data, encoding: .utf8) {
        return json
    }
    return "{ \"type\": \"text\" }"
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
                "\(comment) @raycast.argument\(index + 1) \(argumentMetadataJSON(placeholder: value))"
            )
        }
        lines.append("")
        lines.append(template.bodyPlaceholder)
        lines.append("")
        return lines.joined(separator: "\n")
    }
}

extension ScriptDraft {
    /// Prefills the form from an existing command for editing.
    init(command: ScriptCommand) {
        self.init()
        template = ScriptTemplate.allCases.first { $0.fileExtension == command.url.pathExtension } ?? .bash
        mode = command.mode
        title = command.title
        description = command.description ?? ""
        packageName = command.packageName ?? ""
        needsConfirmation = command.needsConfirmation
        argumentPlaceholders = command.arguments.map(\.placeholder)
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

    /// Rewrites only the managed metadata lines of an existing script,
    /// leaving the shebang, body, and any unmanaged header lines untouched.
    static func update(draft: ScriptDraft, at url: URL, fileManager: FileManager = .default) throws {
        let original = try String(contentsOf: url, encoding: .utf8)
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let permissions = attributes?[.posixPermissions] as? NSNumber ?? NSNumber(value: 0o755)

        try rewriteMetadata(in: original, draft: draft).write(to: url, atomically: true, encoding: .utf8)
        // Atomic writes replace the file, so restore the execute bit.
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    /// Managed keys in the order missing entries are appended to the header.
    private static let managedKeys: [(key: String, canonical: String)] = [
        ("title", "title"),
        ("mode", "mode"),
        ("packagename", "packageName"),
        ("description", "description"),
        ("needsconfirmation", "needsConfirmation"),
        ("argument1", "argument1"),
        ("argument2", "argument2"),
        ("argument3", "argument3")
    ]

    static func rewriteMetadata(in contents: String, draft: ScriptDraft) -> String {
        let scalars = desiredScalars(for: draft)
        let placeholders = desiredArgumentPlaceholders(for: draft)

        var output: [String] = []
        var handled = Set<String>()
        var lastMetadataIndex: Int?
        var commentPrefix: String?

        for (lineNumber, line) in contents.components(separatedBy: "\n").enumerated() {
            // Match the parser's header window so metadata-looking lines in
            // the body (heredocs, generated text) are never touched.
            guard lineNumber < ScriptMetadataParser.maximumHeaderLines,
                  let field = ScriptMetadataParser.metadataField(in: line) else {
                output.append(line)
                continue
            }
            if commentPrefix == nil {
                commentPrefix = line.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "//" : "#"
            }
            let isManaged = managedKeys.contains { $0.key == field.key }
            guard isManaged else {
                output.append(line)
                lastMetadataIndex = output.count - 1
                continue
            }
            // Drop duplicates of managed keys; the parser only reads the first.
            guard !handled.contains(field.key) else { continue }
            handled.insert(field.key)

            guard let updated = updatedLine(
                for: field,
                original: line,
                scalars: scalars,
                placeholders: placeholders,
                comment: commentPrefix ?? "#"
            ) else { continue }
            output.append(updated)
            lastMetadataIndex = output.count - 1
        }

        var insertions: [String] = []
        for entry in managedKeys where !handled.contains(entry.key) {
            let value: String?
            if let index = argumentIndex(for: entry.key) {
                value = placeholders[index].map { argumentMetadataJSON(placeholder: $0) }
            } else {
                value = scalars[entry.key] ?? nil
            }
            guard let value else { continue }
            insertions.append("\(commentPrefix ?? "#") @raycast.\(entry.canonical) \(value)")
        }
        if !insertions.isEmpty {
            let index: Int
            if let lastMetadataIndex {
                index = lastMetadataIndex + 1
            } else if output.first?.hasPrefix("#!") == true {
                index = 1
            } else {
                index = 0
            }
            output.insert(contentsOf: insertions, at: index)
        }
        return output.joined(separator: "\n")
    }

    /// The rewritten metadata line, the original when nothing changed, or nil
    /// when the line should be removed.
    private static func updatedLine(
        for field: (key: String, value: String),
        original: String,
        scalars: [String: String?],
        placeholders: [String?],
        comment: String
    ) -> String? {
        let canonical = managedKeys.first { $0.key == field.key }!.canonical

        if let index = argumentIndex(for: field.key) {
            guard let placeholder = placeholders[index] else { return nil }
            var object = (try? JSONSerialization.jsonObject(
                with: Data(field.value.utf8)
            )) as? [String: Any] ?? ["type": "text"]
            if object["placeholder"] as? String == placeholder { return original }
            object["placeholder"] = placeholder
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let json = String(data: data, encoding: .utf8) else { return original }
            return "\(comment) @raycast.\(canonical) \(json)"
        }

        guard let value = scalars[field.key] ?? nil else {
            // Removing the title would stop the file being a script command.
            return field.key == "title" ? original : nil
        }
        if value == field.value { return original }
        return "\(comment) @raycast.\(canonical) \(value)"
    }

    private static func argumentIndex(for key: String) -> Int? {
        guard key.hasPrefix("argument"), let number = Int(key.dropFirst("argument".count)) else { return nil }
        return number - 1
    }

    private static func desiredScalars(for draft: ScriptDraft) -> [String: String?] {
        let title = draft.title.trimmingCharacters(in: .whitespaces)
        let packageName = draft.packageName.trimmingCharacters(in: .whitespaces)
        let description = draft.description.trimmingCharacters(in: .whitespaces)
        return [
            "title": title.isEmpty ? nil : title,
            "mode": draft.mode.rawValue,
            "packagename": packageName.isEmpty ? nil : packageName,
            "description": description.isEmpty ? nil : description,
            "needsconfirmation": draft.needsConfirmation ? "true" : nil
        ]
    }

    private static func desiredArgumentPlaceholders(for draft: ScriptDraft) -> [String?] {
        var placeholders: [String?] = Array(repeating: nil, count: 3)
        for (index, placeholder) in draft.argumentPlaceholders.prefix(3).enumerated() {
            let trimmed = placeholder.trimmingCharacters(in: .whitespaces)
            placeholders[index] = trimmed.isEmpty ? "Argument \(index + 1)" : trimmed
        }
        return placeholders
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
