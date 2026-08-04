import Foundation

enum ApplicationCatalog {
    static func discoverApplications(fileManager: FileManager = .default) -> [ApplicationRecord] {
        discoverApplications(
            in: searchRoots(homeDirectory: fileManager.homeDirectoryForCurrentUser),
            additionalApplications: [
                URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app", isDirectory: true)
            ],
            fileManager: fileManager
        )
    }

    static func searchRoots(homeDirectory: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true),
            homeDirectory.appendingPathComponent("Applications", isDirectory: true)
        ]
    }

    static func discoverApplications(
        in roots: [URL],
        additionalApplications: [URL] = [],
        fileManager: FileManager = .default
    ) -> [ApplicationRecord] {
        let resourceKeys: [URLResourceKey] = [.isHiddenKey]
        var recordsByID: [String: ApplicationRecord] = [:]

        func addApplication(at url: URL) {
            guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { return }
            let bundle = Bundle(url: url)
            let displayName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            let bundleID = bundle?.bundleIdentifier
            let id = bundleID ?? url.standardizedFileURL.path
            let executable = bundle?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String
            let keywords = [bundleID, executable, url.lastPathComponent]
                .compactMap { $0 }
                .joined(separator: " ")
            let record = ApplicationRecord(id: id, name: displayName, url: url, keywords: keywords)

            if let existing = recordsByID[id] {
                if url.path.count < existing.url.path.count {
                    recordsByID[id] = record
                }
            } else {
                recordsByID[id] = record
            }
        }

        for root in roots where fileManager.fileExists(atPath: root.path) {
            let standardizedRoot = root.standardizedFileURL
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsPackageDescendants]
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                let isApplication = url.pathExtension.caseInsensitiveCompare("app") == .orderedSame
                let isRootLevel = url.deletingLastPathComponent().standardizedFileURL == standardizedRoot
                let isHidden = (try? url.resourceValues(forKeys: [.isHiddenKey]))?.isHidden == true

                if isHidden, !(isApplication && isRootLevel) {
                    enumerator.skipDescendants()
                    continue
                }

                guard isApplication else { continue }
                enumerator.skipDescendants()
                addApplication(at: url)
            }
        }

        for url in additionalApplications where fileManager.fileExists(atPath: url.path) {
            addApplication(at: url)
        }

        return recordsByID.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static var systemSettings: [LauncherItem] {
        settingsDefinitions.compactMap { definition in
            guard let url = URL(string: "x-apple.systempreferences:\(definition.identifier)") else { return nil }
            return LauncherItem(
                id: "settings.\(definition.identifier)",
                title: definition.title,
                subtitle: definition.subtitle,
                kind: .systemSetting,
                destination: .url(url),
                keywords: definition.keywords
            )
        }
    }

    private static let settingsDefinitions: [(title: String, subtitle: String?, identifier: String, keywords: String)] = [
        ("Accessibility", nil, "com.apple.Accessibility-Settings.extension", "voiceover hearing display motor spoken content"),
        ("Appearance", nil, "com.apple.Appearance-Settings.extension", "light dark accent color theme"),
        ("Bluetooth", nil, "com.apple.Bluetooth-Settings.extension", "devices wireless headphones"),
        ("Control Center", nil, "com.apple.ControlCenter-Settings.extension", "menu bar modules"),
        ("Desktop & Dock", nil, "com.apple.Desktop-Settings.extension", "dock windows mission control widgets"),
        ("Displays", nil, "com.apple.Displays-Settings.extension", "monitor resolution brightness night shift"),
        ("General", nil, "com.apple.systempreferences.GeneralSettings", "about storage airdrop software update language login items"),
        ("Keyboard", nil, "com.apple.Keyboard-Settings.extension", "shortcuts input text"),
        ("Lock Screen", nil, "com.apple.Lock-Screen-Settings.extension", "password display sleep"),
        ("Mouse", nil, "com.apple.Mouse-Settings.extension", "pointer scrolling click"),
        ("Network", nil, "com.apple.Network-Settings.extension", "wifi ethernet vpn firewall"),
        ("Notifications", nil, "com.apple.Notifications-Settings.extension", "alerts focus badges"),
        ("Privacy & Security", nil, "com.apple.settings.PrivacySecurity.extension", "location camera microphone permissions filevault"),
        ("Screen Saver", nil, "com.apple.ScreenSaver-Settings.extension", "screensaver clock"),
        ("Sound", nil, "com.apple.Sound-Settings.extension", "audio output input volume alerts"),
        ("Trackpad", nil, "com.apple.Trackpad-Settings.extension", "gestures point click scroll zoom"),
        ("Wallpaper", nil, "com.apple.Wallpaper-Settings.extension", "desktop background picture")
    ]
}
