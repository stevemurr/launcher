import Foundation

final class LauncherSettings: ObservableObject {
    @Published private(set) var hotKey: HotKey
    @Published private(set) var scriptsDirectory: URL
    @Published var hotKeyError: String?

    private let defaults: UserDefaults
    private static let hotKeyKey = "launcher.hotKey"
    private static let scriptsDirectoryKey = "launcher.scriptsDirectory"

    static var defaultScriptsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".launcher/scripts", isDirectory: true)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.hotKeyKey),
           let stored = try? JSONDecoder().decode(HotKey.self, from: data) {
            hotKey = stored
        } else {
            hotKey = .default
        }
        if let path = defaults.string(forKey: Self.scriptsDirectoryKey), !path.isEmpty {
            scriptsDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            scriptsDirectory = Self.defaultScriptsDirectory
        }
    }

    func save(hotKey: HotKey) {
        self.hotKey = hotKey
        if let data = try? JSONEncoder().encode(hotKey) {
            defaults.set(data, forKey: Self.hotKeyKey)
        }
    }

    func save(scriptsDirectory: URL) {
        self.scriptsDirectory = scriptsDirectory
        defaults.set(scriptsDirectory.path, forKey: Self.scriptsDirectoryKey)
    }
}
