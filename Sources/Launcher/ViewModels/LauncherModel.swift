import AppKit
import Foundation

enum LauncherScreen {
    case search
    case settings
    case createScript
}

enum LauncherFocusTarget: Equatable {
    case search
    case argument(Int)
}

enum ScriptRunPhase: Equatable {
    case running
    case finished(ScriptRunResult)
}

struct ScriptRunState: Equatable {
    let script: ScriptCommand
    var phase: ScriptRunPhase
    var output: String
}

struct PendingScriptRun: Equatable {
    let script: ScriptCommand
    let arguments: [String]
}

enum LauncherAction: String, CaseIterable, Identifiable {
    case open
    case showInFinder
    case copyPath
    case copyScriptContents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: "Open"
        case .showInFinder: "Show in Finder"
        case .copyPath: "Copy Path"
        case .copyScriptContents: "Copy Script Contents"
        }
    }

    var symbolName: String {
        switch self {
        case .open: "arrow.up.forward.app"
        case .showInFinder: "folder"
        case .copyPath: "doc.on.doc"
        case .copyScriptContents: "doc.on.clipboard"
        }
    }

    var shortcut: String {
        switch self {
        case .open: "↩"
        case .showInFinder: "⌘↩"
        case .copyPath: "⌘⇧C"
        case .copyScriptContents: "⌥⌘C"
        }
    }
}

final class LauncherModel: ObservableObject {
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            refreshResults(resetSelection: true)
            isOutputExpanded = false
            if let run = scriptRun, run.phase != .running {
                scriptRun = nil
                isRunChipVisible = false
            }
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

    @Published private(set) var scriptRun: ScriptRunState?
    @Published private(set) var isRunChipVisible = false
    @Published var isOutputExpanded = false
    @Published var isRunPalettePresented = false
    @Published private(set) var pendingRun: PendingScriptRun?
    @Published private(set) var focusTarget: LauncherFocusTarget = .search
    @Published var argumentValues: [String] = []
    @Published var scriptDraft = ScriptDraft()
    @Published var createScriptError: String?

    let settings: LauncherSettings
    var onRequestClose: (() -> Void)?
    var onHotKeyChange: ((HotKey) -> Bool)?

    private let isUITesting: Bool
    private let loginItems: LoginItemService
    private let scriptRunner: ScriptRunning
    private let scriptsDirectoryOverride: URL?
    private var applications: [LauncherItem] = []
    private var scripts: [LauncherItem] = []
    private var runGeneration = 0
    private var lastSelectedScriptID: String?
    private let launcherSettingsItem = LauncherItem(
        id: "launcher.settings",
        title: "Launcher Settings",
        subtitle: "General",
        kind: .launcherSetting,
        destination: .launcherSettings,
        keywords: "preferences hotkey shortcut configure login startup"
    )
    private let createScriptItem = LauncherItem(
        id: "launcher.createScript",
        title: "Create Script Command",
        subtitle: "Scripts",
        kind: .launcherSetting,
        destination: .createScript,
        keywords: "new script command shell bash zsh python terminal raycast"
    )

    init(
        settings: LauncherSettings,
        isUITesting: Bool = false,
        loginItems: LoginItemService? = nil,
        scriptRunner: ScriptRunning? = nil
    ) {
        self.settings = settings
        self.isUITesting = isUITesting
        self.loginItems = loginItems ?? (isUITesting ? InMemoryLoginItemService() : AppLoginItemService())
        self.scriptRunner = scriptRunner ?? ProcessScriptRunner()
        self.scriptsDirectoryOverride = isUITesting ? Self.writeUITestFixtureScripts() : nil
        launchAtLogin = self.loginItems.isEnabled
        if isUITesting { applyScripts(ScriptCommandCatalog.discoverScripts(in: effectiveScriptsDirectory)) }
        refreshResults(resetSelection: true)
    }

    var selectedItem: LauncherItem? {
        guard results.indices.contains(selectedIndex) else { return nil }
        return results[selectedIndex]
    }

    var selectedScript: ScriptCommand? {
        guard case let .script(command)? = selectedItem?.destination else { return nil }
        return command
    }

    var availableActions: [LauncherAction] {
        guard let selectedItem else { return [] }
        switch selectedItem.kind {
        case .application: return [.open, .showInFinder, .copyPath]
        case .scriptCommand: return [.open, .showInFinder, .copyScriptContents]
        default: return [.open]
        }
    }

    var effectiveScriptsDirectory: URL {
        scriptsDirectoryOverride ?? settings.scriptsDirectory
    }

    var showMoreAvailable: Bool {
        guard let run = scriptRun else { return false }
        return run.script.mode == .compact || run.script.mode == .fullOutput
    }

    func loadApplications() {
        isLoading = true
        rescanScripts()

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
        isRunPalettePresented = false
        pendingRun = nil
        isOutputExpanded = false
        focusTarget = .search
        rescanScripts()
        if screen == .search {
            query = ""
            selectedIndex = 0
            focusToken += 1
        }
    }

    func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = (selectedIndex + offset + results.count) % results.count
        syncArgumentState()
    }

    func select(index: Int) {
        guard results.indices.contains(index) else { return }
        selectedIndex = index
        syncArgumentState()
    }

    func activateSelected() {
        guard let selectedItem else { return }
        activate(selectedItem)
    }

    func handleSubmit() {
        if pendingRun != nil {
            confirmPendingRun()
            return
        }
        if isOutputExpanded { return }
        activateSelected()
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
        case let .script(command):
            requestRun(command)
        case .createScript:
            scriptDraft = ScriptDraft()
            createScriptError = nil
            screen = .createScript
            isActionsPresented = false
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
        if pendingRun != nil {
            dismissPendingRun()
        } else if isRunPalettePresented {
            isRunPalettePresented = false
        } else if isActionsPresented {
            isActionsPresented = false
        } else if case .argument = focusTarget {
            focusSearch()
        } else if isOutputExpanded {
            isOutputExpanded = false
        } else if screen != .search {
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
        case .copyScriptContents:
            guard let fileURL = selectedItem.fileURL,
                  let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(contents, forType: .string)
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

    // MARK: - Script commands

    func rescanScripts() {
        let directory = effectiveScriptsDirectory
        if isUITesting {
            applyScripts(ScriptCommandCatalog.discoverScripts(in: directory))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let discovered = ScriptCommandCatalog.discoverScripts(in: directory)
            DispatchQueue.main.async { self?.applyScripts(discovered) }
        }
    }

    func updateScriptsDirectory(_ url: URL) {
        settings.save(scriptsDirectory: url)
        rescanScripts()
    }

    private func applyScripts(_ commands: [ScriptCommand]) {
        scripts = commands.map { command in
            LauncherItem(
                id: "script.\(command.id)",
                title: command.title,
                subtitle: command.packageName,
                kind: .scriptCommand,
                destination: .script(command),
                keywords: [command.description, command.packageName, "script command"]
                    .compactMap { $0 }
                    .joined(separator: " ")
            )
        }
        refreshResults(resetSelection: false)
    }

    private func requestRun(_ script: ScriptCommand) {
        if let missingIndex = firstMissingRequiredArgumentIndex(for: script) {
            NSSound.beep()
            focus(.argument(missingIndex))
            return
        }
        let arguments = Array(argumentValues.prefix(script.arguments.count))
        if script.needsConfirmation {
            pendingRun = PendingScriptRun(script: script, arguments: arguments)
        } else {
            startRun(script: script, arguments: arguments)
        }
    }

    func confirmPendingRun() {
        guard let pendingRun else { return }
        self.pendingRun = nil
        startRun(script: pendingRun.script, arguments: pendingRun.arguments)
    }

    func dismissPendingRun() {
        pendingRun = nil
    }

    private func startRun(script: ScriptCommand, arguments: [String]) {
        guard !scriptRunner.isRunning else {
            NSSound.beep()
            isRunPalettePresented = true
            return
        }
        runGeneration += 1
        let generation = runGeneration
        scriptRun = ScriptRunState(script: script, phase: .running, output: "")
        isRunChipVisible = true
        isRunPalettePresented = false
        isOutputExpanded = script.mode == .fullOutput
        focusSearch()
        if script.mode == .silent { onRequestClose?() }
        scriptRunner.run(
            script,
            arguments: arguments,
            onOutput: { [weak self] chunk in self?.appendOutput(chunk, generation: generation) },
            onCompletion: { [weak self] result in self?.finishRun(result, generation: generation) }
        )
    }

    func cancelScriptRun() {
        scriptRunner.cancel()
    }

    func toggleRunPalette() {
        guard scriptRun?.phase == .running else { return }
        isRunPalettePresented.toggle()
    }

    func toggleOutputExpanded() {
        guard showMoreAvailable else { return }
        isOutputExpanded.toggle()
    }

    private static let outputCharacterCap = 100_000

    private func appendOutput(_ chunk: String, generation: Int) {
        guard generation == runGeneration, var run = scriptRun else { return }
        run.output += chunk
        if run.output.count > Self.outputCharacterCap {
            var trimmed = run.output.suffix(Self.outputCharacterCap)
            if let newline = trimmed.firstIndex(of: "\n") {
                trimmed = trimmed[trimmed.index(after: newline)...]
            }
            run.output = String(trimmed)
        }
        scriptRun = run
    }

    private func finishRun(_ result: ScriptRunResult, generation: Int) {
        guard generation == runGeneration, var run = scriptRun else { return }
        run.phase = .finished(result)
        scriptRun = run
        isRunPalettePresented = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.runGeneration == generation else { return }
            self.isRunChipVisible = false
        }
    }

    private func firstMissingRequiredArgumentIndex(for script: ScriptCommand) -> Int? {
        for (index, argument) in script.arguments.enumerated() where !argument.optional {
            let value = argumentValues.indices.contains(index) ? argumentValues[index] : ""
            if value.trimmingCharacters(in: .whitespaces).isEmpty { return index }
        }
        return nil
    }

    // MARK: - Focus

    func focus(_ target: LauncherFocusTarget) {
        focusTarget = target
        focusToken += 1
    }

    func focusSearch() {
        focus(.search)
    }

    func noteFocus(_ target: LauncherFocusTarget) {
        focusTarget = target
    }

    func handleFocusNext() {
        cycleFocus(forward: true)
    }

    func handleFocusPrevious() {
        cycleFocus(forward: false)
    }

    private func cycleFocus(forward: Bool) {
        guard let script = selectedScript, !script.arguments.isEmpty else { return }
        let count = script.arguments.count
        switch focusTarget {
        case .search:
            focus(.argument(forward ? 0 : count - 1))
        case let .argument(index):
            let next = forward ? index + 1 : index - 1
            if next < 0 || next >= count {
                focusSearch()
            } else {
                focus(.argument(next))
            }
        }
    }

    private func syncArgumentState() {
        let scriptID = selectedScript?.id
        guard scriptID != lastSelectedScriptID else { return }
        lastSelectedScriptID = scriptID
        argumentValues = Array(repeating: "", count: selectedScript?.arguments.count ?? 0)
        if focusTarget != .search { focusSearch() }
    }

    // MARK: - Create script

    func createScript(andOpen: Bool) {
        do {
            let url = try ScriptCommandCreator.create(draft: scriptDraft, in: effectiveScriptsDirectory)
            let title = scriptDraft.title
            applyScripts(ScriptCommandCatalog.discoverScripts(in: effectiveScriptsDirectory))
            showSearch()
            query = title
            if andOpen { NSWorkspace.shared.open(url) }
        } catch {
            createScriptError = "Could not create the script: \(error.localizedDescription)"
        }
    }

    private static func writeUITestFixtureScripts() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("launcher-ui-fixtures-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fixtures: [(name: String, contents: String)] = [
            ("say-hello.sh", """
            #!/bin/sh
            # @raycast.title Say Hello
            # @raycast.mode inline
            # @raycast.packageName Fixtures
            echo "Hello from fixture"
            """),
            ("count-lines.sh", """
            #!/bin/sh
            # @raycast.title Count Lines
            # @raycast.mode compact
            # @raycast.packageName Fixtures
            for i in 1 2 3; do
              echo "line $i"
              sleep 0.3
            done
            """),
            ("greet.sh", """
            #!/bin/sh
            # @raycast.title Greet
            # @raycast.mode fullOutput
            # @raycast.packageName Fixtures
            # @raycast.argument1 { "type": "text", "placeholder": "Name" }
            echo "hello-$1"
            """)
        ]
        for fixture in fixtures {
            let url = directory.appendingPathComponent(fixture.name)
            try? fixture.contents.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return directory
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
        let allItems = [launcherSettingsItem, createScriptItem]
            + applications + scripts + ApplicationCatalog.systemSettings
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
        syncArgumentState()
    }
}
