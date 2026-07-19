import Foundation

enum ScriptCommandCatalog {
    private static let headerReadLimit = 4096

    /// Shallow, synchronous scan of the top level of `directory`. A missing
    /// directory yields an empty list. Callers run this off the main queue.
    static func discoverScripts(in directory: URL, fileManager: FileManager = .default) -> [ScriptCommand] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        return entries
            .compactMap { url -> ScriptCommand? in
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                      let handle = try? FileHandle(forReadingFrom: url) else { return nil }
                defer { try? handle.close() }
                guard let data = try? handle.read(upToCount: headerReadLimit), !data.isEmpty else { return nil }
                let header = String(decoding: data, as: UTF8.self)
                return ScriptMetadataParser.parse(contents: header, url: url)
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
