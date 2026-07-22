import Foundation

struct FileEntry: Equatable, Identifiable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let permissions: String

    var id: String { url.path }
}

enum FileListingError: Equatable {
    case notFound
    case notReadable
}

struct FileListing: Equatable {
    let directory: URL
    let iCloudEntry: FileEntry?
    let directories: [FileEntry]
    let files: [FileEntry]
    let error: FileListingError?
    let isTruncated: Bool

    var isEmpty: Bool { iCloudEntry == nil && directories.isEmpty && files.isEmpty }
}

enum FileBrowserEngine {
    static let maxEntries = 250
    static let iCloudDriveName = "iCloud Drive"

    struct BrowseRequest: Equatable {
        let directory: URL
        let filter: String
    }

    static func isPathLike(_ query: String) -> Bool {
        query.hasPrefix("/")
            || query == "~"
            || query.hasPrefix("~/")
            || query.hasPrefix("./")
            || query.hasPrefix("../")
    }

    static func parse(
        _ query: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> BrowseRequest? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPathLike(trimmed) else { return nil }

        let homePath = home.path
        let path: String
        if trimmed == "~" {
            path = homePath + "/"
        } else if trimmed.hasPrefix("~/") {
            path = homePath + "/" + String(trimmed.dropFirst(2))
        } else if trimmed.hasPrefix("./") {
            // The launcher runs as an accessory app with no meaningful cwd, so
            // relative paths resolve against the home directory.
            path = homePath + "/" + String(trimmed.dropFirst(2))
        } else if trimmed.hasPrefix("../") {
            path = home.deletingLastPathComponent().path + "/" + String(trimmed.dropFirst(3))
        } else {
            path = trimmed
        }

        if path.hasSuffix("/") {
            let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            return BrowseRequest(directory: directory, filter: "")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return BrowseRequest(directory: url.deletingLastPathComponent(), filter: url.lastPathComponent)
    }

    static func list(
        directory: URL,
        filter: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> FileListing {
        let iCloudEntry = iCloudEntry(for: directory, filter: filter, home: home, fileManager: fileManager)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return FileListing(
                directory: directory, iCloudEntry: nil, directories: [], files: [],
                error: .notFound, isTruncated: false
            )
        }

        let showsHidden = filter.hasPrefix(".")
        var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
        if !showsHidden { options.insert(.skipsHiddenFiles) }

        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey],
                options: options
            )
        } catch {
            return FileListing(
                directory: directory, iCloudEntry: nil, directories: [], files: [],
                error: .notReadable, isTruncated: false
            )
        }

        // Score names before touching the filesystem again so large directories
        // only pay the per-entry stat for entries that survive the filter.
        let matched: [(url: URL, name: String, score: Int)] = contents.compactMap { url in
            let name = url.lastPathComponent
            guard !filter.isEmpty else { return (url, name, 0) }
            guard let score = SearchMatcher.score(query: filter, title: name) else { return nil }
            return (url, name, score)
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        let isTruncated = matched.count > maxEntries
        let entries = matched.prefix(maxEntries).map { makeEntry(url: $0.url, name: $0.name, fileManager: fileManager) }

        return FileListing(
            directory: directory,
            iCloudEntry: iCloudEntry,
            directories: entries.filter(\.isDirectory),
            files: entries.filter { !$0.isDirectory },
            error: nil,
            isTruncated: isTruncated
        )
    }

    private static func makeEntry(url: URL, name: String, fileManager: FileManager) -> FileEntry {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false

        let permissions: String
        if let mode = (try? fileManager.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber {
            permissions = String(format: "%03o", mode.intValue & 0o777)
        } else {
            permissions = ""
        }

        return FileEntry(
            url: url,
            name: name,
            // Packages (.app bundles and the like) open on Enter instead of descending.
            isDirectory: exists && isDirectory.boolValue && !isPackage,
            permissions: permissions
        )
    }

    private static func iCloudEntry(
        for directory: URL,
        filter: String,
        home: URL,
        fileManager: FileManager
    ) -> FileEntry? {
        guard directory.standardizedFileURL.path == home.standardizedFileURL.path else { return nil }
        let cloudDocs = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: cloudDocs.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        guard filter.isEmpty || SearchMatcher.score(query: filter, title: iCloudDriveName) != nil else { return nil }
        return FileEntry(url: cloudDocs, name: iCloudDriveName, isDirectory: true, permissions: "")
    }
}
