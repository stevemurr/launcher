import Foundation

final class LauncherSettings: ObservableObject {
    @Published private(set) var hotKey: HotKey
    @Published var hotKeyError: String?

    private let defaults: UserDefaults
    private static let hotKeyKey = "launcher.hotKey"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.hotKeyKey),
           let stored = try? JSONDecoder().decode(HotKey.self, from: data) {
            hotKey = stored
        } else {
            hotKey = .default
        }
    }

    func save(hotKey: HotKey) {
        self.hotKey = hotKey
        if let data = try? JSONEncoder().encode(hotKey) {
            defaults.set(data, forKey: Self.hotKeyKey)
        }
    }
}
