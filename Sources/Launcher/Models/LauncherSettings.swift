import Foundation

final class LauncherSettings: ObservableObject {
    @Published private(set) var hotKey: HotKey
    @Published private(set) var scriptsDirectory: URL
    @Published private(set) var terminalSize: LauncherTerminalSize
    @Published var hotKeyError: String?

    private let defaults: UserDefaults
    private static let hotKeyKey = "launcher.hotKey"
    private static let scriptsDirectoryKey = "launcher.scriptsDirectory"
    private static let terminalSizeKey = "launcher.terminalSize"

    static var defaultScriptsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".launcher/scripts", isDirectory: true)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        terminalSize = defaults.string(forKey: Self.terminalSizeKey)
            .flatMap(LauncherTerminalSize.init(rawValue:)) ?? .standard
        if let data = defaults.data(forKey: Self.hotKeyKey),
           let stored = try? JSONDecoder().decode(HotKey.self, from: data) {
            if stored.isSafeGlobalShortcut {
                hotKey = stored
            } else {
                // Older builds allowed Shift-only global shortcuts, which
                // intercept normal uppercase typing system-wide. Migrate them
                // at the persistence boundary so every registration path is safe.
                hotKey = .default
                hotKeyError = "Shift-only shortcuts were reset to Option-Space."
                if let replacement = try? JSONEncoder().encode(HotKey.default) {
                    defaults.set(replacement, forKey: Self.hotKeyKey)
                }
            }
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

    func save(terminalSize: LauncherTerminalSize) {
        self.terminalSize = terminalSize
        defaults.set(terminalSize.rawValue, forKey: Self.terminalSizeKey)
    }
}
