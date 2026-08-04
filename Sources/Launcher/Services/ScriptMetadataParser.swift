import Foundation

/// Parses Raycast-style script command metadata from header comments, e.g.:
///
///     #!/bin/bash
///     # @raycast.title Youtube Download Audio
///     # @raycast.mode compact
///     # @raycast.argument1 { "type": "text", "placeholder": "URL" }
///
/// Both the `@raycast.` and `@launcher.` prefixes are accepted so existing
/// Raycast script commands work as drop-ins.
enum ScriptMetadataParser {
    static let maximumHeaderLines = 50
    private static let maximumArguments = 3

    private static let lineExpression = try! NSRegularExpression(
        pattern: #"^\s*(?:#|//)\s*@(?:raycast|launcher)\.([A-Za-z0-9]+)\s+(\S.*?)\s*$"#
    )

    /// Extracts the lowercased key and raw value from a single metadata line,
    /// or nil when the line is not a metadata comment.
    static func metadataField(in line: String) -> (key: String, value: String)? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = lineExpression.firstMatch(in: line, range: range),
              let keyRange = Range(match.range(at: 1), in: line),
              let valueRange = Range(match.range(at: 2), in: line) else { return nil }
        return (line[keyRange].lowercased(), String(line[valueRange]))
    }

    static func parse(contents: String, url: URL) -> ScriptCommand? {
        var values: [String: String] = [:]

        for line in contents.components(separatedBy: .newlines).prefix(maximumHeaderLines) {
            guard let field = metadataField(in: line) else { continue }
            // First occurrence wins so @raycast and @launcher duplicates don't fight.
            if values[field.key] == nil {
                values[field.key] = field.value
            }
        }

        guard let title = values["title"], !title.isEmpty else { return nil }

        var arguments: [ScriptArgument] = []
        for index in 1...maximumArguments {
            guard let raw = values["argument\(index)"] else { continue }
            arguments.append(parseArgument(raw, index: index))
        }

        return ScriptCommand(
            id: url.path,
            url: url,
            title: title,
            mode: ScriptMode(metadataValue: values["mode"]),
            packageName: values["packagename"],
            description: values["description"],
            needsConfirmation: values["needsconfirmation"] == "true" || values["needsconfirmation"] == "1",
            arguments: arguments
        )
    }

    private static func parseArgument(_ raw: String, index: Int) -> ScriptArgument {
        let fallback = "Argument \(index)"
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ScriptArgument(placeholder: fallback, optional: false)
        }
        let placeholder = object["placeholder"] as? String
        return ScriptArgument(
            placeholder: placeholder?.isEmpty == false ? placeholder! : fallback,
            optional: object["optional"] as? Bool ?? false
        )
    }
}
