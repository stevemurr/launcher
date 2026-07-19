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
    @Published private(set) var calculation: Calculation?
    @Published var selectedIndex = 0
    @Published var screen: LauncherScreen = .search
    @Published var isActionsPresented = false
    @Published var isLoading = false
    @Published var focusToken = 0
    @Published private(set) var launchAtLogin = false
    @Published var launchAtLoginError: String?

    let settings: LauncherSettings
    var onRequestClose: (() -> Void)?
    var onHotKeyChange: ((HotKey) -> Bool)?

    private let isUITesting: Bool
    private let loginItems: LoginItemService
    private var applications: [LauncherItem] = []
    private let launcherSettingsItem = LauncherItem(
        id: "launcher.settings",
        title: "Launcher Settings",
        subtitle: "General",
        kind: .launcherSetting,
        destination: .launcherSettings,
        keywords: "preferences hotkey shortcut configure login startup"
    )

    init(settings: LauncherSettings, isUITesting: Bool = false, loginItems: LoginItemService? = nil) {
        self.settings = settings
        self.isUITesting = isUITesting
        self.loginItems = loginItems ?? (isUITesting ? InMemoryLoginItemService() : AppLoginItemService())
        launchAtLogin = self.loginItems.isEnabled
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
        case let .copyText(text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
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

    func setLaunchAtLogin(_ enabled: Bool) {
        guard enabled != launchAtLogin else { return }
        do {
            try loginItems.setEnabled(enabled)
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Could not update the login item: \(error.localizedDescription)"
        }
        launchAtLogin = loginItems.isEnabled
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

        calculation = trimmedQuery.isEmpty ? nil : CalculatorEngine.evaluate(trimmedQuery)

        if trimmedQuery.isEmpty {
            let suggestedApplications = applications.prefix(5)
            results = [launcherSettingsItem] + suggestedApplications
        } else {
            let matches = allItems
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
                .prefix(calculation == nil ? 6 : 4)
                .map(\.0)

            if let calculation {
                let calculatorItem = LauncherItem(
                    id: "calculator",
                    title: calculation.expression,
                    subtitle: calculation.formattedResult,
                    kind: .calculator,
                    destination: .copyText(calculation.formattedResult),
                    keywords: ""
                )
                results = [calculatorItem] + matches
            } else {
                results = matches
            }
        }

        if resetSelection || !results.indices.contains(selectedIndex) {
            selectedIndex = 0
        }
    }
}
