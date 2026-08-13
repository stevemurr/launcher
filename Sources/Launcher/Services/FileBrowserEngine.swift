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
        let preparedFilter = SearchMatcher.prepare(filter)
        let matched: [(url: URL, name: String, score: Int)] = contents.compactMap { url in
            let name = url.lastPathComponent
            guard !filter.isEmpty else { return (url, name, 0) }
            guard let score = SearchMatcher.score(query: preparedFilter, title: name) else { return nil }
            return (url, name, score)
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        // The UI presents directories before files, so reserve the capped result
        // set for directories first as well. Prefixing the globally name-sorted
        // URLs before classifying them let a large run of early-sorting files hide
        // every later directory, making those folders impossible to navigate to
        // without first knowing their names and filtering for them.
        let classified = matched.map { match in
            (
                url: match.url,
                name: match.name,
                isDirectory: isBrowsableDirectory(match.url, fileManager: fileManager)
            )
        }
        let directoryMatches = classified.filter(\.isDirectory)
        let fileMatches = classified.filter { !$0.isDirectory }
        let selectedDirectories = Array(directoryMatches.prefix(maxEntries))
        let remainingCapacity = maxEntries - selectedDirectories.count
        let selectedFiles = Array(fileMatches.prefix(remainingCapacity))
        let isTruncated = classified.count > selectedDirectories.count + selectedFiles.count
        let directories = selectedDirectories.map {
            makeEntry(url: $0.url, name: $0.name, isDirectory: true, fileManager: fileManager)
        }
        let files = selectedFiles.map {
            makeEntry(url: $0.url, name: $0.name, isDirectory: false, fileManager: fileManager)
        }

        return FileListing(
            directory: directory,
            iCloudEntry: iCloudEntry,
            directories: directories,
            files: files,
            error: nil,
            isTruncated: isTruncated
        )
    }

    private static func isBrowsableDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
        guard values?.isPackage != true else { return false }

        // URLResourceValues describes the link itself. Follow symlinks so a link
        // to a directory remains navigable, matching FileManager's prior behavior.
        if values?.isSymbolicLink == true || values?.isDirectory == nil {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        return values?.isDirectory == true
    }

    private static func makeEntry(
        url: URL,
        name: String,
        isDirectory: Bool,
        fileManager: FileManager
    ) -> FileEntry {

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
            isDirectory: isDirectory,
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
