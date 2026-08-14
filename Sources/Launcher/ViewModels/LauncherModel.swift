import AppKit
import Foundation

enum LauncherScreen {
    case search
    case settings
    case createScript
}

enum LauncherPanelPresentation: Equatable {
    case compact
    case outputDrawer
    case shellConsole

    var isExpanded: Bool { self != .compact }
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

struct ShellRunState: Equatable {
    let id: ShellSessionID
    var command: String
    /// Last foreground-command status, retained for the console badge and for
    /// source compatibility with the previous one-shot run model.
    var phase: ScriptRunPhase
    /// Lifetime state of the persistent shell itself.
    var sessionPhase: ShellSessionPhase
    var output: String
    var didTruncateOutput: Bool
    var workingDirectory: String

    var lastResult: ScriptRunResult? {
        guard case let .finished(result) = phase else { return nil }
        return result
    }
}

enum ShellInputMode: Equatable {
    case idle
    case foreground
}

struct PendingScriptRun: Equatable {
    let script: ScriptCommand
    let arguments: [String]
}

enum LauncherAction: String, CaseIterable, Identifiable {
    case open
    case openWith
    case editScript
    case showInFinder
    case quickLook
    case copyPath
    case copyScriptContents
    case deleteScript

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: "Open"
        case .openWith: "Open With…"
        case .editScript: "Edit Script Command"
        case .showInFinder: "Show in Finder"
        case .quickLook: "Quick Look"
        case .copyPath: "Copy Path"
        case .copyScriptContents: "Copy Script Contents"
        case .deleteScript: "Delete Script Command"
        }
    }

    var symbolName: String {
        switch self {
        case .open: "arrow.up.forward.app"
        case .openWith: "app.badge.checkmark"
        case .editScript: "square.and.pencil"
        case .showInFinder: "folder"
        case .quickLook: "eye"
        case .copyPath: "doc.on.doc"
        case .copyScriptContents: "doc.on.clipboard"
        case .deleteScript: "trash"
        }
    }

    var shortcut: String {
        switch self {
        case .open: "↩"
        case .openWith: "⌘↩"
        case .editScript: "⌘E"
        case .showInFinder: "⌘F"
        case .quickLook: "⌘Y"
        case .copyPath: "⌘⇧C"
        case .copyScriptContents: "⌥⌘C"
        case .deleteScript: "⌃X"
        }
    }
}

struct FileBrowserSession: Equatable {
    var stack: [URL]

    var current: URL { stack[stack.count - 1] }
}

struct OpenWithCandidate: Equatable, Identifiable {
    let url: URL
    let name: String

    var id: String { url.path }
}

private struct SelectedScriptArgumentState: Equatable {
    let scriptID: String
    let schema: [ScriptArgument]
}

private struct PendingShellCompletionRequest {
    let input: String
    let cursorUTF16: Int
    let requestID: ShellCompletionRequestID
    let selectsLastCandidate: Bool
}

/// Synchronous filesystem work cannot always be interrupted once the kernel or
/// a remote filesystem has started it. This token still suppresses work that
/// has not begun and delivery from work that is already in flight.
private final class LatestPendingExecutionRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Runs at most `maximumConcurrent` synchronous operations and retains only one
/// not-yet-started operation: the latest submission. The serial state queue and
/// its single reschedulable timer never wait for a worker slot, so hung workers
/// cannot create a growing collection of libdispatch closures blocked on a
/// semaphore.
private final class LatestPendingExecutor<Output>: @unchecked Sendable {
    private struct Job {
        let request: LatestPendingExecutionRequest
        let operation: () -> Output
        let completion: (LatestPendingExecutionRequest, Output) -> Void
    }

    private let stateQueue: DispatchQueue
    private let workerQueue: DispatchQueue
    private let completionQueue: DispatchQueue
    private let maximumConcurrent: Int
    private let debounce: DispatchTimeInterval
    private let timer: DispatchSourceTimer
    private var activeCount = 0
    private var pendingJob: Job?
    private var pendingIsReady = false

    init(
        label: String,
        maximumConcurrent: Int = 2,
        debounce: DispatchTimeInterval = .milliseconds(75),
        completionQueue: DispatchQueue = .main
    ) {
        precondition(maximumConcurrent > 0)
        self.maximumConcurrent = maximumConcurrent
        self.debounce = debounce
        self.completionQueue = completionQueue
        stateQueue = DispatchQueue(label: "\(label).scheduler", qos: .userInitiated)
        workerQueue = DispatchQueue(label: "\(label).workers", qos: .userInitiated, attributes: .concurrent)
        timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .distantFuture)
        timer.setEventHandler { [weak self] in
            guard let self, self.pendingJob != nil else { return }
            self.pendingIsReady = true
            self.startReadyJobIfPossible()
        }
        timer.resume()
    }

    @discardableResult
    func submit(
        operation: @escaping () -> Output,
        completion: @escaping (LatestPendingExecutionRequest, Output) -> Void
    ) -> LatestPendingExecutionRequest {
        let request = LatestPendingExecutionRequest()
        let job = Job(request: request, operation: operation, completion: completion)
        // Install synchronously so bursts cannot themselves form a backlog of
        // state-update closures behind two hung workers. This queue never runs
        // resolver work, so the critical section stays constant-time.
        stateQueue.sync { [self] in
            pendingJob?.request.cancel()
            pendingJob = job
            pendingIsReady = false
            timer.schedule(deadline: .now() + debounce, leeway: .milliseconds(5))
        }
        return request
    }

    func cancel(_ request: LatestPendingExecutionRequest) {
        request.cancel()
        stateQueue.sync { [self] in
            guard pendingJob?.request === request else { return }
            pendingJob = nil
            pendingIsReady = false
            timer.schedule(deadline: .distantFuture)
        }
    }

    private func startReadyJobIfPossible() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard activeCount < maximumConcurrent,
              pendingIsReady,
              let job = pendingJob else { return }

        pendingJob = nil
        pendingIsReady = false
        guard !job.request.isCancelled else { return }

        activeCount += 1
        workerQueue.async { [self] in
            guard !job.request.isCancelled else {
                stateQueue.async { [self] in finishJob() }
                return
            }

            let output = job.operation()
            stateQueue.async { [self] in
                activeCount -= 1
                if !job.request.isCancelled {
                    completionQueue.async {
                        guard !job.request.isCancelled else { return }
                        job.completion(job.request, output)
                    }
                }
                startReadyJobIfPossible()
            }
        }
    }

    private func finishJob() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        activeCount -= 1
        startReadyJobIfPossible()
    }
}

final class LauncherModel: ObservableObject {
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            if isConsumingShellTrigger { return }

            if !isShellMode, query.hasPrefix(">") {
                enterShellMode(consuming: query)
                return
            }
            if isShellMode, isAwaitingShellSeparator {
                isAwaitingShellSeparator = false
                if query.hasPrefix(" ") {
                    isConsumingShellTrigger = true
                    query.removeFirst()
                    isConsumingShellTrigger = false
                    refreshResults(resetSelection: true)
                    return
                }
            }
            if isActionsPresented {
                isActionsPresented = false
                actionsTarget = nil
            }
            if isOpenWithPresented {
                isOpenWithPresented = false
                openWithTarget = nil
            }
            if isShellMode, !isApplyingShellHistory {
                resetShellHistoryNavigation()
            }
            if isShellMode {
                dismissShellCompletion()
            }
            refreshResults(resetSelection: true)
            if isShellMode {
                clearFinishedScriptRun()
            } else {
                clearFinishedRuns()
            }
        }
    }
    @Published private(set) var results: [LauncherItem] = []
    @Published private(set) var calculation: Calculation?
    @Published var selectedIndex = 0
    @Published var screen: LauncherScreen = .search {
        didSet {
            // Settings and Create Script render at full window width.
            if screen != .search { setPanelPresentation(.compact) }
        }
    }
    @Published var isActionsPresented = false
    @Published var actionsSelectionIndex = 0
    @Published private(set) var actionsTarget: LauncherItem?
    @Published var isLoading = false
    @Published var focusToken = 0
    @Published private(set) var launchAtLogin = false
    @Published var launchAtLoginError: String?

    @Published private(set) var scriptRun: ScriptRunState?
    @Published private(set) var isShellMode = false
    @Published private(set) var shellSessions: [ShellRunState] = []
    @Published private(set) var selectedShellSessionID: ShellSessionID?
    @Published private(set) var shellCompletions: [String] = []
    @Published private(set) var shellCompletionSelectionIndex = 0
    @Published private(set) var panelPresentation: LauncherPanelPresentation = .compact
    @Published var isRunPalettePresented = false
    @Published private(set) var pendingRun: PendingScriptRun?
    @Published private(set) var focusTarget: LauncherFocusTarget = .search
    @Published var argumentValues: [String] = []
    @Published var scriptDraft = ScriptDraft()
    @Published var createScriptError: String?
    @Published private(set) var editingScriptURL: URL?
    @Published private(set) var pendingDeletion: ScriptCommand?

    @Published private(set) var browseSession: FileBrowserSession?
    @Published private(set) var fileListing: FileListing?
    @Published private(set) var isFileListingLoading = false
    @Published var isOpenWithPresented = false
    @Published private(set) var openWithApps: [OpenWithCandidate] = []
    @Published var openWithSelectionIndex = 0
    @Published private(set) var openWithTarget: URL?

    let settings: LauncherSettings
    var onRequestClose: (() -> Void)?
    var onOutputPanePresentationChange: ((Bool) -> Void)?
    var onHotKeyChange: ((HotKey) -> Bool)?
    var onQuickLook: ((URL) -> Void)?
    var applicationFinder: (URL) -> [URL] = { url in
        NSWorkspace.shared.urlsForApplications(toOpen: url)
    }
    var urlOpener: (URL) -> Void = { url in
        _ = NSWorkspace.shared.open(url)
    }
    var fileRevealer: (URL) -> Void = { url in
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    var applicationOpener: (URL, URL) -> Void = { fileURL, applicationURL in
        NSWorkspace.shared.open(
            [fileURL],
            withApplicationAt: applicationURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    private let isUITesting: Bool
    private let loginItems: LoginItemService
    private let scriptRunner: ScriptRunning
    private let shellSessionManager: PersistentShellSessionManaging
    private let scriptsDirectoryOverride: URL?
    private let browseHomeOverride: URL?
    private let fileListingResolver: (FileBrowserSession?, String, URL) -> FileListing?
    private let resolvesFileListingsSynchronously: Bool
    private let scriptDiscoverer: (URL) -> [ScriptCommand]
    private let fileListingExecutor = LatestPendingExecutor<FileListing?>(label: "Launcher.file-listing")
    private let scriptScanExecutor = LatestPendingExecutor<[ScriptCommand]>(label: "Launcher.script-scan")
    private var applications: [LauncherItem] = []
    private var scripts: [LauncherItem] = []
    private var runGeneration = 0
    private var browseGeneration = 0
    private var scriptScanGeneration = 0
    private var fileListingRequest: LatestPendingExecutionRequest?
    private var scriptScanRequest: LatestPendingExecutionRequest?
    private var selectedScriptArgumentState: SelectedScriptArgumentState?
    private var shellHistory: [String] = []
    private var shellHistoryIndex = 0
    private var shellHistoryDraft = ""
    private var isApplyingShellHistory = false
    private var isConsumingShellTrigger = false
    private var isAwaitingShellSeparator = false
    private var activeShellCompletionRequestID: ShellCompletionRequestID?
    private var shellCompletionReplacementRange: Range<Int>?
    private var shellCompletionSelectsLastCandidate = false
    private var pendingShellCommands: [ShellSessionID: String] = [:]
    private var pendingShellCompletionRequests: [ShellSessionID: PendingShellCompletionRequest] = [:]
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
        scriptRunner: ScriptRunning? = nil,
        shellRunner: ShellCommandRunning? = nil,
        shellJobManager: ShellJobManaging? = nil,
        shellSessionManager: PersistentShellSessionManaging? = nil,
        browseHome: URL? = nil,
        resolvesFileListingsSynchronously: Bool? = nil,
        fileListingResolver: ((FileBrowserSession?, String, URL) -> FileListing?)? = nil,
        scriptDiscoverer: ((URL) -> [ScriptCommand])? = nil
    ) {
        let defaultProcessRunner = ProcessScriptRunner()
        self.settings = settings
        self.isUITesting = isUITesting
        self.loginItems = loginItems ?? (isUITesting ? InMemoryLoginItemService() : AppLoginItemService())
        self.scriptRunner = scriptRunner ?? defaultProcessRunner
        if let shellSessionManager {
            self.shellSessionManager = shellSessionManager
        } else if let shellJobManager {
            self.shellSessionManager = LegacyPersistentShellSessionManager(jobManager: shellJobManager)
        } else if let shellRunner {
            self.shellSessionManager = LegacyPersistentShellSessionManager(
                jobManager: SingleRunnerShellJobManager(runner: shellRunner)
            )
        } else if let sharedRunner = scriptRunner as? ShellCommandRunning {
            self.shellSessionManager = LegacyPersistentShellSessionManager(
                jobManager: SingleRunnerShellJobManager(runner: sharedRunner)
            )
        } else {
            self.shellSessionManager = ProcessPersistentShellSessionManager()
        }
        self.scriptsDirectoryOverride = isUITesting ? Self.writeUITestFixtureScripts() : nil
        self.browseHomeOverride = browseHome ?? (isUITesting ? Self.writeUITestFixtureFiles() : nil)
        self.resolvesFileListingsSynchronously = resolvesFileListingsSynchronously
            ?? (isUITesting || browseHome != nil)
        self.fileListingResolver = fileListingResolver ?? Self.resolveListing
        self.scriptDiscoverer = scriptDiscoverer ?? { ScriptCommandCatalog.discoverScripts(in: $0) }
        launchAtLogin = self.loginItems.isEnabled
        if isUITesting { applyScripts(self.scriptDiscoverer(effectiveScriptsDirectory)) }
        refreshResults(resetSelection: true)
    }

    var shellRun: ShellRunState? {
        guard let selectedShellSessionID else { return nil }
        return shellSessions.first { $0.id == selectedShellSessionID }
    }

    var shellInputMode: ShellInputMode {
        shellRun?.sessionPhase == .foreground ? .foreground : .idle
    }

    var shellWorkingDirectoryDisplay: String {
        guard let directory = shellRun?.workingDirectory, !directory.isEmpty else { return "~" }
        return displayShellDirectory(directory)
    }

    private func displayShellDirectory(_ directory: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if directory == home { return "~" }
        if directory.hasPrefix(home + "/") { return "~" + directory.dropFirst(home.count) }
        return directory
    }

    var selectedItem: LauncherItem? {
        guard !isShellMode else { return nil }
        guard results.indices.contains(selectedIndex) else { return nil }
        return results[selectedIndex]
    }

    var isPanelExpanded: Bool { panelPresentation.isExpanded }

    var isOutputPanePresented: Bool { panelPresentation == .outputDrawer }

    /// Running shell rows are always a contiguous prefix of ordinary search
    /// results so the view can render them in their own pinned section.
    var runningShellResultCount: Int {
        results.prefix { $0.kind == .runningShell }.count
    }

    var selectedScript: ScriptCommand? {
        guard case let .script(command)? = selectedItem?.destination else { return nil }
        return command
    }

    var availableActions: [LauncherAction] {
        let item = isActionsPresented ? actionsTarget : selectedItem
        guard let item else { return [] }
        switch item.kind {
        case .application: return [.open, .showInFinder, .copyPath]
        case .scriptCommand: return [.open, .editScript, .showInFinder, .copyScriptContents, .deleteScript]
        case .file, .directory: return [.open, .openWith, .showInFinder, .quickLook, .copyPath]
        default: return [.open]
        }
    }

    var isFileBrowsing: Bool { !isShellMode && (isFileListingLoading || fileListing != nil) }

    /// The directory represented by the file-browser UI, including the brief
    /// interval after a derived path query starts but before its async listing
    /// arrives. Keeping this available lets VoiceOver describe the pending file
    /// search instead of falling back to applications and settings.
    var browseDirectoryForAccessibility: URL? {
        guard !isShellMode else { return nil }
        if let browseSession { return browseSession.current }
        if let fileListing { return fileListing.directory }
        guard isFileListingLoading else { return nil }
        return FileBrowserEngine.parse(query, home: browseHome)?.directory
    }

    var searchFieldPlaceholder: String {
        if isShellMode {
            if shellInputMode == .foreground {
                let command = shellRun?.command.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return command.isEmpty ? "Send input…" : "Send input to \(command)…"
            }
            return "Enter a shell command…"
        }
        guard let session = browseSession else { return "Search applications and settings" }
        let path = session.current.path
        return "Search in \(path == "/" ? "/" : path + "/")…"
    }

    var searchFieldAccessibilityLabel: String {
        if isShellMode {
            return shellInputMode == .foreground ? "Shell standard input" : "Shell command"
        }
        return LauncherSearchField.contextualAccessibilityLabel(for: browseDirectoryForAccessibility)
    }

    var effectiveScriptsDirectory: URL {
        scriptsDirectoryOverride ?? settings.scriptsDirectory
    }

    /// The chip lives exactly as long as the run it describes.
    var isRunChipVisible: Bool { scriptRun != nil || (isShellMode && shellRun != nil) }

    var displayedRunPhase: ScriptRunPhase? {
        if let shellRun {
            // The command's result remains in `phase` for transcript/testing,
            // but the persistent session is once again usable at `.ready`.
            return shellRun.sessionPhase == .ready ? nil : shellRun.phase
        }
        return scriptRun?.phase
    }

    var displayedRunTitle: String {
        if let shellRun { return shellRun.command }
        return scriptRun?.script.title ?? ""
    }

    var displayedRunIsShell: Bool { shellRun != nil }

    /// A foreground command is interrupted in place. A shell that has not
    /// reached its first prompt is different: there is no foreground command
    /// to signal, so Stop closes the whole unusable session instead.
    var canStopShellSession: Bool {
        guard isShellMode, let phase = shellRun?.sessionPhase else { return false }
        return phase == .starting || phase == .foreground
    }

    /// Whether there is output worth showing in the ⌘P pane. Silent scripts opt
    /// out of output entirely, so the pane stays empty even while one runs.
    var isOutputAvailable: Bool {
        if shellRun != nil { return true }
        guard let run = scriptRun else { return false }
        return run.script.mode != .silent
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

    func reindex() {
        guard !isLoading else { return }
        rescanScripts()
        loadApplications()
    }

    func prepareForPresentation(screen: LauncherScreen = .search) {
        self.screen = screen
        isActionsPresented = false
        actionsSelectionIndex = 0
        actionsTarget = nil
        isRunPalettePresented = false
        isOpenWithPresented = false
        pendingRun = nil
        pendingDeletion = nil
        editingScriptURL = nil
        setPanelPresentation(.compact)
        focusTarget = .search
        browseSession = nil
        if isShellMode {
            discardSelectedShellIfFinished()
            isShellMode = false
            selectedShellSessionID = nil
            dismissShellCompletion()
            resetShellHistoryNavigation()
        }
        rescanScripts()
        // query.didSet is guarded against no-op assignments, so a launcher
        // dismissed with an empty query would otherwise reopen still showing
        // the last run's chip.
        clearFinishedRuns()
        if query.isEmpty {
            // query.didSet is guarded against no-op assignments. Refreshing
            // here is essential when Launcher was hidden from sticky browse
            // mode with an already-empty query; otherwise Settings can reopen
            // over a stale listing whose navigation session was discarded.
            refreshResults(resetSelection: true)
        } else {
            query = ""
        }
        selectedIndex = 0
        if screen == .search {
            focusToken += 1
        }
    }

    func moveSelection(by offset: Int) {
        if isShellMode {
            if !shellCompletions.isEmpty {
                moveShellCompletion(by: offset)
                return
            }
            guard shellInputMode == .idle else { return }
            moveShellHistory(by: offset)
            return
        }
        if isOpenWithPresented {
            guard !openWithApps.isEmpty else { return }
            openWithSelectionIndex = (openWithSelectionIndex + offset + openWithApps.count) % openWithApps.count
            return
        }
        if isActionsPresented {
            let count = availableActions.count
            guard count > 0 else { return }
            actionsSelectionIndex = (actionsSelectionIndex + offset + count) % count
            return
        }
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
        if isShellMode {
            submitShellCommand()
            return
        }
        if isOpenWithPresented {
            confirmOpenWith()
            return
        }
        if pendingDeletion != nil {
            confirmPendingDeletion()
            return
        }
        if pendingRun != nil {
            confirmPendingRun()
            return
        }
        if isActionsPresented {
            let actions = availableActions
            if actions.indices.contains(actionsSelectionIndex) {
                perform(actions[actionsSelectionIndex])
            }
            return
        }
        // Never execute an item from the previous search while a path listing
        // is replacing it. The visible results are cleared immediately too,
        // but this guard is a second line of defense for programmatic callers.
        guard !isFileListingLoading else { return }
        activateSelected()
    }

    func activate(_ item: LauncherItem) {
        switch item.destination {
        case .launcherSettings:
            showSettings()
        case let .url(url):
            // A cold launch can keep the workspace call busy long enough for
            // the panel to linger, so dismiss before handing off the URL.
            onRequestClose?()
            urlOpener(url)
        case let .copyText(text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            onRequestClose?()
        case let .script(command):
            requestRun(command)
        case .createScript:
            scriptDraft = ScriptDraft()
            createScriptError = nil
            editingScriptURL = nil
            screen = .createScript
            isActionsPresented = false
        case let .browseDirectory(url):
            descend(into: url)
        case let .shellSession(id):
            resumeShellSession(id: id)
        }
    }

    func showSettings() {
        screen = .settings
        isActionsPresented = false
        actionsTarget = nil
    }

    func showSearch() {
        screen = .search
        isActionsPresented = false
        actionsTarget = nil
        editingScriptURL = nil
        setPanelPresentation(isShellMode ? .shellConsole : .compact)
        focusToken += 1
    }

    func handleEscape() {
        if pendingDeletion != nil {
            dismissPendingDeletion()
        } else if pendingRun != nil {
            dismissPendingRun()
        } else if isRunPalettePresented {
            isRunPalettePresented = false
        } else if isOpenWithPresented {
            isOpenWithPresented = false
            openWithTarget = nil
        } else if isActionsPresented {
            isActionsPresented = false
            actionsTarget = nil
        } else if screen == .search, case .argument = focusTarget {
            focusSearch()
        } else if isOutputPanePresented {
            dismissOutputPane()
        } else if screen == .search, isShellMode, !shellCompletions.isEmpty {
            dismissShellCompletion()
        } else if screen == .search, isShellMode {
            exitShellMode()
        } else if isFileBrowsing {
            ascendOrExitBrowse()
        } else if screen != .search {
            showSearch()
        } else {
            onRequestClose?()
        }
    }

    func toggleActions() {
        guard !isShellMode else { return }
        if isActionsPresented {
            isActionsPresented = false
            actionsTarget = nil
            return
        }
        guard selectedItem != nil, pendingRun == nil, pendingDeletion == nil else { return }
        if isOpenWithPresented {
            isOpenWithPresented = false
            openWithTarget = nil
        }
        actionsSelectionIndex = 0
        actionsTarget = selectedItem
        isActionsPresented = true
    }

    func perform(_ action: LauncherAction) {
        let target = isActionsPresented ? actionsTarget : selectedItem
        guard let target else { return }
        isActionsPresented = false
        actionsTarget = nil

        switch action {
        case .open:
            activate(target)
        case .openWith:
            presentOpenWith(for: target)
        case .quickLook:
            guard let fileURL = target.fileURL else { return }
            onQuickLook?(fileURL)
        case .editScript:
            guard case let .script(script) = target.destination else { return }
            beginEditing(script)
        case .deleteScript:
            guard case let .script(script) = target.destination else { return }
            requestDeleting(script)
        case .showInFinder:
            guard let fileURL = target.fileURL else { return }
            onRequestClose?()
            fileRevealer(fileURL)
        case .copyPath:
            guard let fileURL = target.fileURL else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(fileURL.path, forType: .string)
        case .copyScriptContents:
            guard let fileURL = target.fileURL,
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
        guard hotKey.isSafeGlobalShortcut else {
            settings.hotKeyError = "Use Control, Option, or Command in the shortcut."
            return
        }
        if onHotKeyChange?(hotKey) ?? true {
            settings.save(hotKey: hotKey)
            settings.hotKeyError = nil
        } else {
            settings.hotKeyError = "That shortcut is already used by another application."
        }
    }

    // MARK: - File browsing

    func descend(into url: URL) {
        var stack = browseSession?.stack ?? []
        if stack.isEmpty, let listing = fileListing {
            // Entering sticky mode from a typed path: seed the stack with the
            // listed directory so Escape returns to it before exiting.
            stack.append(listing.directory)
        }
        stack.append(url)
        browseSession = FileBrowserSession(stack: stack)
        if query.isEmpty {
            refreshResults(resetSelection: true)
        } else {
            query = ""
        }
        focusSearch()
    }

    func ascendOrExitBrowse() {
        if var session = browseSession {
            session.stack.removeLast()
            browseSession = session.stack.isEmpty ? nil : session
            if query.isEmpty {
                refreshResults(resetSelection: true)
            } else {
                query = ""
            }
            focusSearch()
        } else if isFileListingLoading || fileListing != nil {
            // Derived mode always has a non-empty path-like query; clearing it
            // exits the browser via query.didSet.
            query = ""
        }
    }

    private var browseHome: URL {
        browseHomeOverride ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private func applyBrowseResults(filter trimmedQuery: String, resetSelection: Bool) {
        let session = browseSession
        let home = browseHome

        cancelFileListingRequest()
        fileListing = nil
        results = []
        selectedIndex = 0
        isFileListingLoading = true
        syncArgumentState()

        // Tests drive `query`/`browseSession` and assert on `results`/`fileListing`
        // synchronously, so keep the UI-testing and fixed-home (unit test) paths
        // inline. Real usage (no override) offloads the directory listing since
        // it enumerates and locale-sorts the whole directory on every keystroke.
        if resolvesFileListingsSynchronously {
            let listing = fileListingResolver(session, trimmedQuery, home)
            isFileListingLoading = false
            applyListing(listing, resetSelection: resetSelection)
            return
        }

        let generation = browseGeneration
        let resolver = fileListingResolver
        fileListingRequest = fileListingExecutor.submit(
            operation: { resolver(session, trimmedQuery, home) },
            completion: { [weak self] request, listing in
                guard let self,
                      self.browseGeneration == generation,
                      self.fileListingRequest === request else { return }
                self.fileListingRequest = nil
                self.isFileListingLoading = false
                self.applyListing(listing, resetSelection: resetSelection)
            }
        )
    }

    private func cancelFileListingRequest() {
        browseGeneration += 1
        if let fileListingRequest {
            fileListingExecutor.cancel(fileListingRequest)
        }
        fileListingRequest = nil
        isFileListingLoading = false
    }

    private static func resolveListing(
        session: FileBrowserSession?,
        filter trimmedQuery: String,
        home: URL
    ) -> FileListing? {
        if let session {
            return FileBrowserEngine.list(directory: session.current, filter: trimmedQuery, home: home)
        } else if let request = FileBrowserEngine.parse(trimmedQuery, home: home) {
            return FileBrowserEngine.list(directory: request.directory, filter: request.filter, home: home)
        } else {
            return nil
        }
    }

    private func applyListing(_ listing: FileListing?, resetSelection: Bool) {
        guard let listing else {
            fileListing = nil
            results = []
            return
        }

        fileListing = listing
        var items: [LauncherItem] = []
        if let iCloudEntry = listing.iCloudEntry {
            items.append(makeFileItem(iCloudEntry, isICloud: true))
        }
        items += listing.directories.map { makeFileItem($0) }
        items += listing.files.map { makeFileItem($0) }
        results = items

        if resetSelection || !results.indices.contains(selectedIndex) {
            selectedIndex = 0
        }
        syncArgumentState()
    }

    private func makeFileItem(_ entry: FileEntry, isICloud: Bool = false) -> LauncherItem {
        LauncherItem(
            id: isICloud ? "file.icloud" : "file.\(entry.url.path)",
            title: entry.name,
            subtitle: nil,
            kind: entry.isDirectory ? .directory : .file,
            destination: entry.isDirectory ? .browseDirectory(entry.url) : .url(entry.url),
            keywords: "",
            detail: entry.permissions.isEmpty ? nil : entry.permissions
        )
    }

    // MARK: - Open With

    var openWithTitle: String {
        guard let openWithTarget else { return "Open With" }
        return "Open \(FileManager.default.displayName(atPath: openWithTarget.path)) With"
    }

    func presentOpenWith() {
        guard let selectedItem else { return }
        presentOpenWith(for: selectedItem)
    }

    private func presentOpenWith(for item: LauncherItem) {
        guard let fileURL = item.fileURL else { return }
        isActionsPresented = false
        actionsTarget = nil
        openWithTarget = fileURL
        openWithApps = applicationFinder(fileURL).prefix(8).map { url in
            OpenWithCandidate(url: url, name: FileManager.default.displayName(atPath: url.path))
        }
        openWithSelectionIndex = 0
        isOpenWithPresented = true
    }

    func selectOpenWith(index: Int) {
        guard openWithApps.indices.contains(index) else { return }
        openWithSelectionIndex = index
    }

    func confirmOpenWith() {
        guard isOpenWithPresented else { return }
        isOpenWithPresented = false
        guard openWithApps.indices.contains(openWithSelectionIndex),
              let fileURL = openWithTarget else { return }
        let applicationURL = openWithApps[openWithSelectionIndex].url
        openWithTarget = nil
        onRequestClose?()
        applicationOpener(fileURL, applicationURL)
    }

    // MARK: - Script commands

    func rescanScripts() {
        scriptScanGeneration += 1
        let generation = scriptScanGeneration
        let directory = effectiveScriptsDirectory
        if let scriptScanRequest {
            scriptScanExecutor.cancel(scriptScanRequest)
        }
        scriptScanRequest = nil
        if isUITesting {
            applyScripts(scriptDiscoverer(directory))
            return
        }
        let discoverer = scriptDiscoverer
        scriptScanRequest = scriptScanExecutor.submit(
            operation: { discoverer(directory) },
            completion: { [weak self] request, discovered in
                guard let self,
                      self.scriptScanGeneration == generation,
                      self.scriptScanRequest === request else { return }
                self.scriptScanRequest = nil
                self.applyScripts(discovered)
            }
        )
    }

    func updateScriptsDirectory(_ url: URL) {
        settings.save(scriptsDirectory: url)
        // Commands from the previous directory must stop being actionable
        // before the asynchronous scan of the new directory begins.
        applyScripts([])
        rescanScripts()
    }

    private func applyScripts(_ commands: [ScriptCommand]) {
        let selectedID = selectedItem?.id
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
        // Application/script catalog updates are unrelated to the file rows
        // already on screen. Refreshing while browsing would cancel and repeat
        // a potentially slow network-directory enumeration.
        guard !isShellMode,
              browseSession == nil,
              !FileBrowserEngine.isPathLike(query.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }
        refreshResults(resetSelection: false, preserving: selectedID)
    }

    private var knownScriptCommands: [ScriptCommand] {
        scripts.compactMap { item in
            guard case let .script(command) = item.destination else { return nil }
            return command
        }
    }

    private func upsertScript(_ command: ScriptCommand) {
        var commands = knownScriptCommands.filter { $0.id != command.id }
        commands.append(command)
        commands.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        applyScripts(commands)
    }

    private func removeScript(withID id: String) {
        applyScripts(knownScriptCommands.filter { $0.id != id })
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

    func beginEditingSelectedScript() {
        guard let script = selectedScript else { return }
        beginEditing(script)
    }

    private func beginEditing(_ script: ScriptCommand) {
        // Re-read the file so the form reflects edits made outside the app
        // since the last scan.
        let command: ScriptCommand
        if let contents = try? String(contentsOf: script.url, encoding: .utf8),
           let parsed = ScriptMetadataParser.parse(contents: contents, url: script.url) {
            command = parsed
        } else {
            command = script
        }
        scriptDraft = ScriptDraft(command: command)
        editingScriptURL = command.url
        createScriptError = nil
        screen = .createScript
        isActionsPresented = false
        actionsTarget = nil
    }

    func requestDeletingSelectedScript() {
        guard let script = selectedScript else { return }
        requestDeleting(script)
    }

    private func requestDeleting(_ script: ScriptCommand) {
        pendingDeletion = script
        isActionsPresented = false
        actionsTarget = nil
    }

    func confirmPendingDeletion() {
        guard let pendingDeletion else { return }
        self.pendingDeletion = nil
        do {
            try FileManager.default.removeItem(at: pendingDeletion.url)
            scriptScanGeneration += 1
            if let scriptScanRequest {
                scriptScanExecutor.cancel(scriptScanRequest)
            }
            scriptScanRequest = nil
            removeScript(withID: pendingDeletion.id)
            // Reconcile against disk because the incremental view may have been
            // based on a still-in-flight cold scan.
            rescanScripts()
        } catch {
            NSSound.beep()
        }
    }

    func dismissPendingDeletion() {
        pendingDeletion = nil
    }

    private func startRun(script: ScriptCommand, arguments: [String]) {
        guard scriptRun?.phase != .running,
              !scriptRunner.isRunning else {
            NSSound.beep()
            isRunPalettePresented = true
            return
        }
        discardSelectedShellIfFinished()
        selectedShellSessionID = nil
        runGeneration += 1
        let generation = runGeneration
        scriptRun = ScriptRunState(script: script, phase: .running, output: "")
        isRunPalettePresented = false
        // Runs never open the pane on their own: the footer chip is the
        // notification, ⌘P is the escalation. An already-open pane simply
        // re-binds to the new run.
        focusSearch()
        if script.mode == .silent { onRequestClose?() }
        scriptRunner.run(
            script,
            arguments: arguments,
            onOutput: { [weak self] chunk in
                guard script.mode != .silent else { return }
                self?.appendOutput(chunk, generation: generation)
            },
            onCompletion: { [weak self] result in self?.finishRun(result, generation: generation) }
        )
    }

    func cancelScriptRun() {
        scriptRunner.cancel()
    }

    func cancelShellCommand() {
        guard let id = selectedShellSessionID,
              let index = shellSessions.firstIndex(where: { $0.id == id }) else { return }
        switch shellSessions[index].sessionPhase {
        case .starting:
            // Startup files are arbitrary user code and can block forever.
            // Closing is the only meaningful cancellation before the first
            // Ready event; publish it immediately so Stop cannot appear stuck
            // while the service performs graceful-then-forced teardown.
            shellSessions[index].sessionPhase = .closing
            pendingShellCommands[id] = nil
            pendingShellCompletionRequests[id] = nil
            dismissShellCompletion()
            shellSessionManager.closeSession(id)
        case .foreground:
            shellSessionManager.interruptForeground(in: id)
        case .ready, .closing:
            break
        }
    }

    func cancelCurrentRun() {
        if canStopShellSession {
            cancelShellCommand()
        } else if scriptRun?.phase == .running {
            scriptRunner.cancel()
        }
    }

    var hasRunningProcess: Bool {
        scriptRun?.phase == .running || canStopShellSession
    }

    func terminateRunningProcess() {
        shellSessionManager.terminateAllImmediately()
        scriptRunner.terminateImmediately()
    }

    func toggleRunPalette() {
        guard displayedRunPhase == .running else { return }
        isRunPalettePresented.toggle()
    }

    func toggleOutputPane() {
        guard !isShellMode else { return }
        // Never toggle out from under a modal confirmation.
        guard isOutputPanePresented || (pendingRun == nil && pendingDeletion == nil) else { return }
        if !isOutputPanePresented, isActionsPresented {
            isActionsPresented = false
            actionsTarget = nil
        }
        setPanelPresentation(isOutputPanePresented ? .compact : .outputDrawer)
        // Deliberately no focusSearch() here, matching toggleActions() and
        // toggleRunPalette(): focusSearch() re-selects the whole query, so the
        // next keystroke would wipe what the user typed. Nothing in the pane is
        // focusable, and key commands route through the responder chain, so
        // opening it cannot strand focus.
    }

    func dismissOutputPane() {
        guard isOutputPanePresented else { return }
        setPanelPresentation(.compact)
    }

    private func setPanelPresentation(_ presentation: LauncherPanelPresentation) {
        guard panelPresentation != presentation else { return }
        let wasExpanded = panelPresentation.isExpanded
        panelPresentation = presentation
        let isExpanded = presentation.isExpanded
        guard wasExpanded != isExpanded else { return }
        // Must stay synchronous: showLauncher() relies on the panel having
        // already shrunk before positionPanel() centers it.
        onOutputPanePresentationChange?(isExpanded)
    }

    /// Drops a run that has already completed, along with the pane showing it.
    /// A *running* run is left alone: losing the chip would strand the process
    /// with no ⌘T cancel affordance, and closing a live stream because the user
    /// typed would be hostile.
    private func clearFinishedScriptRun() {
        guard let run = scriptRun, run.phase != .running else { return }
        scriptRun = nil
        if shellRun == nil { dismissOutputPane() }
    }

    private func clearFinishedShellRun() {
        discardSelectedShellIfFinished()
        if shellRun == nil, scriptRun == nil { dismissOutputPane() }
    }

    private func clearFinishedRuns() {
        clearFinishedScriptRun()
        clearFinishedShellRun()
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
    }

    // MARK: - Shell commands

    private var shellCommandDraft: String {
        isShellMode ? query : ""
    }

    /// `>` is a launcher gesture, not part of the command prompt. Consume it
    /// (and one optional visual separator) while keeping the same AppKit text
    /// field mounted so first-responder and caret state remain stable.
    private func enterShellMode(consuming triggeredInput: String) {
        var draft = String(triggeredInput.dropFirst())
        if draft.first == " " { draft.removeFirst() }

        isActionsPresented = false
        actionsTarget = nil
        isOpenWithPresented = false
        openWithTarget = nil
        pendingRun = nil
        pendingDeletion = nil
        isRunPalettePresented = false
        selectedShellSessionID = nil
        dismissShellCompletion()
        isShellMode = true
        // Normal typing reports `>` and its following space as separate AppKit
        // edits. Remember the bare trigger so the next edit can consume that
        // conventional separator just like a pasted `> command` string.
        isAwaitingShellSeparator = triggeredInput == ">"
        resetShellHistoryNavigation()

        isConsumingShellTrigger = true
        query = draft
        isConsumingShellTrigger = false

        refreshResults(resetSelection: true)
        clearFinishedScriptRun()
    }

    private func exitShellMode() {
        guard isShellMode else { return }
        discardSelectedShellIfFinished()
        // A live job remains in `shellSessions` and is discoverable through the
        // Running Shells section, but it is no longer the displayed run once its
        // console closes. This keeps global run/output shortcuts from binding to
        // a hidden shell; selecting its result establishes the selection again.
        selectedShellSessionID = nil
        dismissShellCompletion()
        isShellMode = false
        isAwaitingShellSeparator = false
        resetShellHistoryNavigation()

        isConsumingShellTrigger = true
        query = ""
        isConsumingShellTrigger = false
        refreshResults(resetSelection: true)
    }

    func resumeShellSession(id: ShellJobID) {
        resumeShellSession(id: ShellSessionID(rawValue: id.rawValue))
    }

    func resumeShellSession(id: ShellSessionID) {
        guard shellSessions.contains(where: { $0.id == id && $0.sessionPhase != .closing }) else {
            refreshResults(resetSelection: true)
            return
        }

        isActionsPresented = false
        actionsTarget = nil
        isOpenWithPresented = false
        openWithTarget = nil
        pendingRun = nil
        pendingDeletion = nil
        isRunPalettePresented = false
        selectedShellSessionID = id
        isShellMode = true
        isAwaitingShellSeparator = false
        resetShellHistoryNavigation()
        dismissShellCompletion()

        isConsumingShellTrigger = true
        query = ""
        isConsumingShellTrigger = false
        refreshResults(resetSelection: true)
        clearFinishedScriptRun()
    }

    private func submitShellCommand() {
        let input = shellCommandDraft

        if shellInputMode == .foreground {
            guard let id = selectedShellSessionID else { return }
            if shellSessionManager.sendInputLine(input, to: id) {
                clearShellDraft()
            } else {
                NSSound.beep()
            }
            return
        }

        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard scriptRun?.phase != .running, !scriptRunner.isRunning else {
            NSSound.beep()
            isRunPalettePresented = true
            return
        }

        scriptRun = nil
        runGeneration += 1
        dismissShellCompletion()

        if let run = shellRun {
            switch run.sessionPhase {
            case .ready:
                _ = submitShellCommand(input, to: run.id)
            case .starting:
                pendingShellCommands[run.id] = input
            case .foreground:
                // `shellInputMode` handled this above. Keep the draft intact if
                // an event races the published state.
                break
            case .closing:
                _ = startShellSession(pendingCommand: input)
            }
        } else {
            _ = startShellSession(pendingCommand: input)
        }
    }

    private static let shellOutputCharacterCap = 100_000
    private static let shellTruncationMarker = "[earlier output truncated]\n"

    private func startShellSession(
        pendingCommand: String? = nil,
        pendingCompletion: PendingShellCompletionRequest? = nil
    ) -> Bool {
        let previousRun = shellRun
        let previousSelection = selectedShellSessionID
        let id = ShellSessionID()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var nextRun = ShellRunState(
            id: id,
            command: "",
            phase: .running,
            sessionPhase: .starting,
            output: previousRun?.sessionPhase == .closing ? (previousRun?.output ?? "") : "",
            didTruncateOutput: previousRun?.sessionPhase == .closing
                ? (previousRun?.didTruncateOutput ?? false)
                : false,
            workingDirectory: home
        )
        trimShellOutputIfNeeded(&nextRun)
        shellSessions.append(nextRun)
        selectedShellSessionID = id
        if let pendingCommand { pendingShellCommands[id] = pendingCommand }
        if let pendingCompletion { pendingShellCompletionRequests[id] = pendingCompletion }

        let accepted = shellSessionManager.startSession(
            id: id,
            onOutput: { [weak self] callbackID, chunk in
                self?.appendShellOutput(chunk, id: callbackID)
            },
            onEvent: { [weak self] callbackID, event in
                self?.handleShellSessionEvent(event, id: callbackID)
            }
        )
        guard accepted else {
            shellSessions.removeAll { $0.id == id }
            pendingShellCommands[id] = nil
            pendingShellCompletionRequests[id] = nil
            selectedShellSessionID = previousSelection
            NSSound.beep()
            return false
        }

        if let previousRun, previousRun.sessionPhase == .closing {
            shellSessions.removeAll { $0.id == previousRun.id }
        }
        return true
    }

    @discardableResult
    private func submitShellCommand(_ command: String, to id: ShellSessionID) -> Bool {
        guard let index = shellSessions.firstIndex(where: { $0.id == id }),
              shellSessions[index].sessionPhase == .ready else { return false }
        let previousRun = shellSessions[index]
        var run = previousRun
        if !run.output.isEmpty {
            if !run.output.hasSuffix("\n") { run.output += "\n" }
            run.output += "\n"
        }
        run.output += "$ \(command)\n"
        run.command = command
        run.phase = .running
        trimShellOutputIfNeeded(&run)
        shellSessions[index] = run

        guard shellSessionManager.submitCommand(command, to: id) else {
            if let currentIndex = shellSessions.firstIndex(where: { $0.id == id }),
               shellSessions[currentIndex].sessionPhase == .ready {
                shellSessions[currentIndex] = previousRun
            }
            NSSound.beep()
            return false
        }

        appendShellHistory(command)
        shellHistoryIndex = shellHistory.count
        shellHistoryDraft = ""
        clearShellDraft()
        isRunPalettePresented = false
        return true
    }

    private func clearShellDraft() {
        isConsumingShellTrigger = true
        query = ""
        isConsumingShellTrigger = false
        resetShellHistoryNavigation()
        dismissShellCompletion()
        if focusTarget != .search { focusTarget = .search }
    }

    private func appendShellOutput(_ chunk: String, id: ShellSessionID) {
        guard let index = shellSessions.firstIndex(where: { $0.id == id }) else { return }
        guard !chunk.isEmpty else { return }
        var run = shellSessions[index]
        run.output += chunk
        trimShellOutputIfNeeded(&run)
        shellSessions[index] = run
    }

    private func handleShellSessionEvent(_ event: ShellSessionEvent, id: ShellSessionID) {
        guard let index = shellSessions.firstIndex(where: { $0.id == id }) else { return }
        var run = shellSessions[index]
        // Once the user has closed a wedged startup, a late Ready/S/F frame
        // must not resurrect it or submit the command that was queued before
        // cancellation. Only the terminal Closed event remains actionable.
        if run.sessionPhase == .closing {
            guard case .closed = event else { return }
        }
        switch event {
        case let .ready(cwd):
            run.sessionPhase = .ready
            run.workingDirectory = cwd
            shellSessions[index] = run
            refreshBackgroundShellResultsIfVisible()
            if let command = pendingShellCommands.removeValue(forKey: id) {
                _ = submitShellCommand(command, to: id)
            } else if let request = pendingShellCompletionRequests.removeValue(forKey: id) {
                performShellCompletionRequest(request, in: id)
            }

        case let .foregroundStarted(command):
            run.command = command
            run.phase = .running
            run.sessionPhase = .foreground
            shellSessions[index] = run
            if selectedShellSessionID == id { dismissShellCompletion() }
            refreshBackgroundShellResultsIfVisible()

        case let .foregroundFinished(result, cwd):
            if case let .failedToStart(message) = result {
                if !run.output.isEmpty, !run.output.hasSuffix("\n") { run.output += "\n" }
                run.output += "Failed to start: \(message)\n"
            }
            run.phase = .finished(result)
            run.sessionPhase = .ready
            run.workingDirectory = cwd
            trimShellOutputIfNeeded(&run)
            shellSessions[index] = run
            isRunPalettePresented = false
            refreshBackgroundShellResultsIfVisible()

        case let .closed(result):
            run.phase = .finished(result)
            run.sessionPhase = .closing
            trimShellOutputIfNeeded(&run)
            shellSessions[index] = run
            pendingShellCommands[id] = nil
            pendingShellCompletionRequests[id] = nil
            if activeShellCompletionRequestID != nil, selectedShellSessionID == id {
                dismissShellCompletion()
            }
            if !isShellMode || selectedShellSessionID != id {
                shellSessions.removeAll { $0.id == id }
                if selectedShellSessionID == id { selectedShellSessionID = nil }
                refreshBackgroundShellResultsIfVisible()
            }
        }
    }

    /// `results` contains value snapshots rather than bindings into
    /// `shellSessions`. Keep a background row's Ready/Running label current as
    /// lifecycle events arrive, without restarting an unrelated file browse.
    private func refreshBackgroundShellResultsIfVisible() {
        guard !isShellMode,
              browseSession == nil,
              !FileBrowserEngine.isPathLike(query.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }
        let selectedItemID = selectedItem?.id
        refreshResults(resetSelection: false, preserving: selectedItemID)
    }

    private func trimShellOutputIfNeeded(_ run: inout ShellRunState) {
        guard run.output.count > Self.shellOutputCharacterCap else { return }
        let retainedCount = max(0, Self.shellOutputCharacterCap - Self.shellTruncationMarker.count)
        var trimmed = run.output.suffix(retainedCount)
        if let newline = trimmed.firstIndex(of: "\n") {
            trimmed = trimmed[trimmed.index(after: newline)...]
        }
        run.output = Self.shellTruncationMarker + trimmed
        run.didTruncateOutput = true
    }

    func requestShellCompletion(backward: Bool = false) {
        guard isShellMode, shellInputMode == .idle else {
            dismissShellCompletion()
            return
        }
        if !shellCompletions.isEmpty {
            moveShellCompletion(by: backward ? -1 : 1)
            return
        }

        dismissShellCompletion()
        let requestID = ShellCompletionRequestID()
        let request = PendingShellCompletionRequest(
            input: query,
            cursorUTF16: (query as NSString).length,
            requestID: requestID,
            selectsLastCandidate: backward
        )
        activeShellCompletionRequestID = requestID
        shellCompletionSelectsLastCandidate = backward

        if let run = shellRun {
            switch run.sessionPhase {
            case .ready:
                performShellCompletionRequest(request, in: run.id)
            case .starting:
                pendingShellCompletionRequests[run.id] = request
            case .foreground:
                dismissShellCompletion()
            case .closing:
                if !startShellSession(pendingCompletion: request) { dismissShellCompletion() }
            }
        } else if !startShellSession(pendingCompletion: request) {
            dismissShellCompletion()
        }
    }

    private func performShellCompletionRequest(
        _ request: PendingShellCompletionRequest,
        in id: ShellSessionID
    ) {
        guard activeShellCompletionRequestID == request.requestID,
              shellSessions.contains(where: { $0.id == id && $0.sessionPhase == .ready }) else { return }
        shellSessionManager.requestCompletions(
            input: request.input,
            cursorUTF16: request.cursorUTF16,
            in: id,
            requestID: request.requestID,
            completion: { [weak self] callbackID, result in
                self?.receiveShellCompletion(result, from: callbackID)
            }
        )
    }

    private func receiveShellCompletion(
        _ result: ShellCompletionResult,
        from id: ShellSessionID
    ) {
        guard isShellMode,
              selectedShellSessionID == id,
              shellRun?.sessionPhase == .ready,
              activeShellCompletionRequestID == result.requestID else { return }
        let length = (query as NSString).length
        guard result.replacementRange.lowerBound >= 0,
              result.replacementRange.upperBound >= result.replacementRange.lowerBound,
              result.replacementRange.upperBound <= length else {
            dismissShellCompletion()
            return
        }

        var seen = Set<String>()
        shellCompletions = result.candidates.filter { !$0.isEmpty && seen.insert($0).inserted }
        shellCompletionReplacementRange = result.replacementRange
        shellCompletionSelectionIndex = shellCompletionSelectsLastCandidate
            ? max(0, shellCompletions.count - 1)
            : 0
        if shellCompletions.isEmpty { dismissShellCompletion() }
    }

    func moveShellCompletion(by offset: Int) {
        guard !shellCompletions.isEmpty, offset != 0 else { return }
        shellCompletionSelectionIndex = (
            shellCompletionSelectionIndex + offset % shellCompletions.count + shellCompletions.count
        ) % shellCompletions.count
    }

    func acceptShellCompletion() {
        acceptShellCompletion(at: shellCompletionSelectionIndex)
    }

    func acceptShellCompletion(at index: Int) {
        guard shellCompletions.indices.contains(index),
              let replacementRange = shellCompletionReplacementRange else { return }
        let candidate = shellCompletions[index]
        let source = query as NSString
        guard replacementRange.upperBound <= source.length else {
            dismissShellCompletion()
            return
        }
        query = source.replacingCharacters(
            in: NSRange(
                location: replacementRange.lowerBound,
                length: replacementRange.upperBound - replacementRange.lowerBound
            ),
            with: candidate
        )
        dismissShellCompletion()
    }

    func dismissShellCompletion() {
        if let requestID = activeShellCompletionRequestID {
            pendingShellCompletionRequests = pendingShellCompletionRequests.filter {
                $0.value.requestID != requestID
            }
        }
        activeShellCompletionRequestID = nil
        shellCompletionReplacementRange = nil
        shellCompletionSelectsLastCandidate = false
        shellCompletions = []
        shellCompletionSelectionIndex = 0
    }

    private func moveShellHistory(by offset: Int) {
        guard !shellHistory.isEmpty, offset != 0 else { return }
        if shellHistoryIndex == shellHistory.count {
            shellHistoryDraft = shellCommandDraft
        }
        let nextIndex = min(max(shellHistoryIndex + offset, 0), shellHistory.count)
        guard nextIndex != shellHistoryIndex else { return }
        shellHistoryIndex = nextIndex
        let command = nextIndex == shellHistory.count ? shellHistoryDraft : shellHistory[nextIndex]
        isApplyingShellHistory = true
        query = command
        isApplyingShellHistory = false
    }

    private func discardSelectedShellIfFinished() {
        guard let id = selectedShellSessionID,
              let run = shellSessions.first(where: { $0.id == id }),
              run.sessionPhase == .closing else { return }
        shellSessions.removeAll { $0.id == id }
        selectedShellSessionID = nil
    }

    private func resetShellHistoryNavigation() {
        shellHistoryIndex = shellHistory.count
        shellHistoryDraft = ""
    }

    private static let maximumShellHistoryEntries = 50
    private static let maximumShellHistoryCharacters = 100_000

    private func appendShellHistory(_ command: String) {
        if shellHistory.last != command { shellHistory.append(command) }
        var characterCount = shellHistory.reduce(0) { $0 + $1.count }
        while shellHistory.count > Self.maximumShellHistoryEntries
            || characterCount > Self.maximumShellHistoryCharacters {
            characterCount -= shellHistory.removeFirst().count
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
        let nextState = selectedScript.map {
            SelectedScriptArgumentState(scriptID: $0.id, schema: $0.arguments)
        }
        guard nextState != selectedScriptArgumentState else { return }

        let previousState = selectedScriptArgumentState
        let previousValues = argumentValues
        selectedScriptArgumentState = nextState

        guard let nextState else {
            argumentValues = []
            if focusTarget != .search { focusSearch() }
            return
        }

        argumentValues = nextState.schema.enumerated().map { index, argument in
            // A rescan can replace a command at the same URL with a new argument
            // schema. Preserve only values whose positional argument is unchanged;
            // new or edited arguments must start empty so stale input cannot be
            // passed under different semantics.
            guard previousState?.scriptID == nextState.scriptID,
                  previousState?.schema.indices.contains(index) == true,
                  previousState?.schema[index] == argument,
                  previousValues.indices.contains(index) else { return "" }
            return previousValues[index]
        }
        if focusTarget != .search { focusSearch() }
    }

    // MARK: - Create / edit script

    func saveScriptDraft(andOpen: Bool) {
        do {
            let url: URL
            if let editingScriptURL {
                try ScriptCommandCreator.update(draft: scriptDraft, at: editingScriptURL)
                url = editingScriptURL
            } else {
                url = try ScriptCommandCreator.create(draft: scriptDraft, in: effectiveScriptsDirectory)
            }
            let title = scriptDraft.title
            scriptScanGeneration += 1
            if let scriptScanRequest {
                scriptScanExecutor.cancel(scriptScanRequest)
            }
            scriptScanRequest = nil
            // Parse the file that was actually written. Edits deliberately
            // preserve unmanaged metadata and argument JSON fields (including
            // `optional`), which `ScriptDraft.fileContents()` cannot represent.
            if let contents = try? String(contentsOf: url, encoding: .utf8),
               let command = ScriptMetadataParser.parse(contents: contents, url: url) {
                upsertScript(command)
            }
            // Reconcile against disk because the incremental view may have been
            // based on a still-in-flight cold scan.
            rescanScripts()
            showSearch()
            query = title
            if andOpen {
                onRequestClose?()
                urlOpener(url)
            }
        } catch {
            let verb = editingScriptURL == nil ? "create" : "save"
            createScriptError = "Could not \(verb) the script: \(error.localizedDescription)"
        }
    }

    private static func writeUITestFixtureScripts() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("launcher-ui-fixtures-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // The three legacy mode spellings below are deliberate: they give the
        // UI tests end-to-end coverage that fullOutput/compact/inline all still
        // parse as .normal. Do not "modernize" them.
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

    private static func writeUITestFixtureFiles() -> URL {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("launcher-ui-files-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        let alpha = home.appendingPathComponent("Alpha", isDirectory: true)
        try? fileManager.createDirectory(at: alpha, withIntermediateDirectories: true)

        let files: [(path: URL, contents: String, permissions: Int)] = [
            (alpha.appendingPathComponent("Inner.txt"), "inner fixture", 0o644),
            (home.appendingPathComponent("Notes.txt"), "notes fixture", 0o644),
            (home.appendingPathComponent("Read Me.md"), "readme fixture", 0o644),
            (home.appendingPathComponent(".hidden.txt"), "hidden fixture", 0o644)
        ]
        for file in files {
            try? file.contents.write(to: file.path, atomically: true, encoding: .utf8)
            try? fileManager.setAttributes([.posixPermissions: file.permissions], ofItemAtPath: file.path.path)
        }
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: alpha.path)
        return home
    }

    private func apply(records: [ApplicationRecord]) {
        let selectedID = selectedItem?.id
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
        guard !isShellMode,
              browseSession == nil,
              !FileBrowserEngine.isPathLike(query.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }
        refreshResults(resetSelection: true, preserving: selectedID)
    }

    private func refreshResults(resetSelection: Bool, preserving selectedID: String? = nil) {
        if isShellMode {
            cancelFileListingRequest()
            browseSession = nil
            fileListing = nil
            calculation = nil
            results = []
            selectedIndex = 0
            syncArgumentState()
            setPanelPresentation(.shellConsole)
            return
        }

        if panelPresentation == .shellConsole {
            setPanelPresentation(.compact)
        }
        let runningShellItems = shellSessions.reversed().compactMap { run -> LauncherItem? in
            guard run.sessionPhase != .closing else { return nil }
            let title = run.command.isEmpty ? "Shell Session" : run.command
            let stateDescription: String
            switch run.sessionPhase {
            case .starting: stateDescription = "Starting Shell"
            case .ready: stateDescription = "Ready in \(displayShellDirectory(run.workingDirectory))"
            case .foreground: stateDescription = "Running in Shell"
            case .closing: return nil
            }
            return LauncherItem(
                id: "shell.\(run.id.rawValue.uuidString)",
                title: title,
                subtitle: stateDescription,
                kind: .runningShell,
                destination: .shellSession(run.id),
                keywords: "running shell terminal command \(run.command) \(run.workingDirectory)",
                detail: run.sessionPhase == .foreground ? "Running" : "Ready"
            )
        }
        let allItems = [launcherSettingsItem, createScriptItem]
            + applications + scripts + ApplicationCatalog.systemSettings
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if browseSession != nil || FileBrowserEngine.isPathLike(trimmedQuery) {
            calculation = nil
            applyBrowseResults(filter: trimmedQuery, resetSelection: resetSelection)
            return
        }
        // Leaving path mode must also cancel any listing already running on
        // the background queue; otherwise its late result can replace this
        // newer application/settings search.
        cancelFileListingRequest()
        fileListing = nil

        calculation = trimmedQuery.isEmpty ? nil : CalculatorEngine.evaluate(trimmedQuery)

        if trimmedQuery.isEmpty {
            let suggestedApplications = applications.prefix(5)
            results = runningShellItems + [launcherSettingsItem] + suggestedApplications
        } else {
            let preparedQuery = SearchMatcher.prepare(trimmedQuery)
            let matches = allItems
                .compactMap { item -> (LauncherItem, Int)? in
                    guard let score = SearchMatcher.score(
                        query: preparedQuery,
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
                results = runningShellItems + [calculatorItem] + matches
            } else {
                results = runningShellItems + matches
            }
        }

        if let selectedID, let index = results.firstIndex(where: { $0.id == selectedID }) {
            selectedIndex = index
        } else if resetSelection || !results.indices.contains(selectedIndex) {
            selectedIndex = 0
        }
        syncArgumentState()
    }
}
