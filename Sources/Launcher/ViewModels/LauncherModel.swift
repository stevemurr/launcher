import AppKit
import Foundation

enum LauncherScreen {
    case search
    case settings
}

enum LauncherAction: String, CaseIterable, Identifiable {
    case open
    case showInFinder
    case copyPath

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: "Open"
        case .showInFinder: "Show in Finder"
        case .copyPath: "Copy Path"
        }
    }

    var symbolName: String {
        switch self {
        case .open: "arrow.up.forward.app"
        case .showInFinder: "folder"
        case .copyPath: "doc.on.doc"
        }
    }

    var shortcut: String {
        switch self {
        case .open: "↩"
        case .showInFinder: "⌘↩"
        case .copyPath: "⌘⇧C"
        }
    }
}

final class LauncherModel: ObservableObject {
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            refreshResults(resetSelection: true)
        }
    }
    @Published private(set) var results: [LauncherItem] = []
    @Published var selectedIndex = 0
    @Published var screen: LauncherScreen = .search
    @Published var isActionsPresented = false
    @Published var isLoading = false
    @Published var focusToken = 0

    let settings: LauncherSettings
    var onRequestClose: (() -> Void)?
    var onHotKeyChange: ((HotKey) -> Bool)?

    private let isUITesting: Bool
    private var applications: [LauncherItem] = []
    private let launcherSettingsItem = LauncherItem(
        id: "launcher.settings",
        title: "Launcher Settings",
        subtitle: "General",
        kind: .launcherSetting,
        destination: .launcherSettings,
        keywords: "preferences hotkey shortcut configure"
    )

    init(settings: LauncherSettings, isUITesting: Bool = false) {
        self.settings = settings
        self.isUITesting = isUITesting
        refreshResults(resetSelection: true)
    }

    var selectedItem: LauncherItem? {
        guard results.indices.contains(selectedIndex) else { return nil }
        return results[selectedIndex]
    }

    var availableActions: [LauncherAction] {
        guard let selectedItem else { return [] }
        if selectedItem.kind == .application { return LauncherAction.allCases }
        return [.open]
    }

    func loadApplications() {
        isLoading = true

        if isUITesting {
            let fixtures = [
                ApplicationRecord(
                    id: "com.apple.ActivityMonitor",
                    name: "Activity Monitor",
                    url: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
                    keywords: "activity cpu memory energy disk network"
                ),
                ApplicationRecord(
                    id: "com.apple.calculator",
                    name: "Calculator",
                    url: URL(fileURLWithPath: "/System/Applications/Calculator.app"),
                    keywords: "math numbers"
                ),
                ApplicationRecord(
                    id: "com.apple.finder",
                    name: "Finder",
                    url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
                    keywords: "files folders"
                )
            ]
            apply(records: fixtures)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let records = ApplicationCatalog.discoverApplications()
            DispatchQueue.main.async { self?.apply(records: records) }
        }
    }

    func prepareForPresentation(screen: LauncherScreen = .search) {
        self.screen = screen
        isActionsPresented = false
        if screen == .search {
            query = ""
            selectedIndex = 0
            focusToken += 1
        }
    }

    func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = (selectedIndex + offset + results.count) % results.count
    }

    func select(index: Int) {
        guard results.indices.contains(index) else { return }
        selectedIndex = index
    }

    func activateSelected() {
        guard let selectedItem else { return }
        activate(selectedItem)
    }

    func activate(_ item: LauncherItem) {
        switch item.destination {
        case .launcherSettings:
            showSettings()
        case let .url(url):
            NSWorkspace.shared.open(url)
            onRequestClose?()
        }
    }

    func showSettings() {
        screen = .settings
        isActionsPresented = false
    }

    func showSearch() {
        screen = .search
        isActionsPresented = false
        focusToken += 1
    }

    func handleEscape() {
        if isActionsPresented {
            isActionsPresented = false
        } else if screen == .settings {
            showSearch()
        } else {
            onRequestClose?()
        }
    }

    func toggleActions() {
        guard selectedItem != nil else { return }
        isActionsPresented.toggle()
    }

    func perform(_ action: LauncherAction) {
        guard let selectedItem else { return }
        isActionsPresented = false

        switch action {
        case .open:
            activate(selectedItem)
        case .showInFinder:
            guard let fileURL = selectedItem.fileURL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            onRequestClose?()
        case .copyPath:
            guard let fileURL = selectedItem.fileURL else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(fileURL.path, forType: .string)
        }
    }

    func updateHotKey(_ hotKey: HotKey) {
        if onHotKeyChange?(hotKey) ?? true {
            settings.save(hotKey: hotKey)
            settings.hotKeyError = nil
        } else {
            settings.hotKeyError = "That shortcut is already used by another application."
        }
    }

    private func apply(records: [ApplicationRecord]) {
        applications = records.map { record in
            LauncherItem(
                id: "application.\(record.id)",
                title: record.name,
                subtitle: nil,
                kind: .application,
                destination: .url(record.url),
                keywords: record.keywords
            )
        }
        isLoading = false
        refreshResults(resetSelection: true)
    }

    private func refreshResults(resetSelection: Bool) {
        let allItems = [launcherSettingsItem] + applications + ApplicationCatalog.systemSettings
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedQuery.isEmpty {
            let suggestedApplications = applications.prefix(5)
            results = [launcherSettingsItem] + suggestedApplications
        } else {
            results = allItems
                .compactMap { item -> (LauncherItem, Int)? in
                    guard let score = SearchMatcher.score(
                        query: trimmedQuery,
                        title: item.title,
                        keywords: [item.subtitle, item.keywords].compactMap { $0 }.joined(separator: " ")
                    ) else { return nil }
                    return (item, score)
                }
                .sorted { lhs, rhs in
                    if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                    if lhs.0.kind != rhs.0.kind {
                        return lhs.0.kind == .application
                    }
                    return lhs.0.title.localizedStandardCompare(rhs.0.title) == .orderedAscending
                }
                .prefix(6)
                .map(\.0)
        }

        if resetSelection || !results.indices.contains(selectedIndex) {
            selectedIndex = 0
        }
    }
}
