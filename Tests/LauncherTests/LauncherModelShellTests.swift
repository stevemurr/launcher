import XCTest
@testable import Launcher

private final class ShellTestLoginItemService: LoginItemService {
    var isEnabled = false
    func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}

private final class StubShellRunner: ShellCommandRunning {
    var isRunning = false
    private(set) var commands: [String] = []
    private(set) var cancellationCount = 0
    private var onOutput: ((String) -> Void)?
    private var onCompletion: ((ScriptRunResult) -> Void)?

    @discardableResult
    func runShellCommand(
        _ rawCommand: String,
        onOutput: @escaping (String) -> Void,
        onCompletion: @escaping (ScriptRunResult) -> Void
    ) -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        commands.append(rawCommand)
        self.onOutput = onOutput
        self.onCompletion = onCompletion
        return true
    }

    func cancel() {
        guard isRunning else { return }
        cancellationCount += 1
        finish(.cancelled)
    }

    func emit(_ chunk: String) {
        guard isRunning else { return }
        onOutput?(chunk)
    }

    func finish(_ result: ScriptRunResult) {
        guard isRunning else { return }
        isRunning = false
        let completion = onCompletion
        onOutput = nil
        onCompletion = nil
        completion?(result)
    }
}

private final class StubBusyScriptRunner: ScriptRunning {
    var isRunning = true

    func run(
        _ command: ScriptCommand,
        arguments: [String],
        onOutput: @escaping (String) -> Void,
        onCompletion: @escaping (ScriptRunResult) -> Void
    ) -> Bool {
        false
    }

    func cancel() {}
}

private final class StubAcceptingScriptRunner: ScriptRunning {
    var isRunning = false
    private(set) var command: ScriptCommand?
    private var onCompletion: ((ScriptRunResult) -> Void)?

    func run(
        _ command: ScriptCommand,
        arguments: [String],
        onOutput: @escaping (String) -> Void,
        onCompletion: @escaping (ScriptRunResult) -> Void
    ) -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        self.command = command
        self.onCompletion = onCompletion
        return true
    }

    func cancel() { finish(.cancelled) }

    func finish(_ result: ScriptRunResult) {
        guard isRunning else { return }
        isRunning = false
        onCompletion?(result)
        onCompletion = nil
    }
}

private final class StubShellJobManager: ShellJobManaging {
    private struct Job {
        let command: String
        let onOutput: (ShellJobID, String) -> Void
        let onCompletion: (ShellJobID, ScriptRunResult) -> Void
    }

    private var jobs: [ShellJobID: Job] = [:]
    var acceptsRuns = true
    private(set) var commands: [(id: ShellJobID, command: String)] = []
    private(set) var cancelledIDs: [ShellJobID] = []
    private(set) var immediateTerminationCount = 0

    var isRunning: Bool { !jobs.isEmpty }
    var activeJobIDs: Set<ShellJobID> { Set(jobs.keys) }

    @discardableResult
    func runShellCommand(
        _ rawCommand: String,
        id: ShellJobID,
        onOutput: @escaping (ShellJobID, String) -> Void,
        onCompletion: @escaping (ShellJobID, ScriptRunResult) -> Void
    ) -> Bool {
        guard acceptsRuns, jobs[id] == nil else { return false }
        jobs[id] = Job(command: rawCommand, onOutput: onOutput, onCompletion: onCompletion)
        commands.append((id, rawCommand))
        return true
    }

    func cancel(_ id: ShellJobID) {
        guard jobs[id] != nil else { return }
        cancelledIDs.append(id)
        finish(id, result: .cancelled)
    }

    func terminateAllImmediately() {
        immediateTerminationCount += 1
        for id in activeJobIDs { finish(id, result: .cancelled) }
    }

    func emit(_ id: ShellJobID, _ chunk: String) {
        jobs[id]?.onOutput(id, chunk)
    }

    func finish(_ id: ShellJobID, result: ScriptRunResult) {
        guard let job = jobs.removeValue(forKey: id) else { return }
        job.onCompletion(id, result)
    }
}

private final class StubPersistentShellSessionManager: PersistentShellSessionManaging {
    private struct Session {
        let onOutput: (ShellSessionID, String) -> Void
        let onEvent: (ShellSessionID, ShellSessionEvent) -> Void
    }

    struct CompletionRequest {
        let input: String
        let cursorUTF16: Int
        let sessionID: ShellSessionID
        let requestID: ShellCompletionRequestID
        let completion: (ShellSessionID, ShellCompletionResult) -> Void
    }

    private var sessions: [ShellSessionID: Session] = [:]
    var automaticallyBecomesReady = true
    var initialWorkingDirectory = "/Users/tester"
    var acceptsSessionStarts = true
    var acceptsCommands = true
    var acceptsInput = true
    var automaticallyClosesOnRequest = true
    private(set) var startedSessionIDs: [ShellSessionID] = []
    private(set) var submittedCommands: [(ShellSessionID, String)] = []
    private(set) var sentInputLines: [(ShellSessionID, String)] = []
    private(set) var interruptedSessionIDs: [ShellSessionID] = []
    private(set) var completionRequests: [CompletionRequest] = []
    private(set) var closedSessionIDs: [ShellSessionID] = []
    private(set) var immediateTerminationCount = 0

    var activeSessionIDs: Set<ShellSessionID> { Set(sessions.keys) }

    @discardableResult
    func startSession(
        id: ShellSessionID,
        onOutput: @escaping (ShellSessionID, String) -> Void,
        onEvent: @escaping (ShellSessionID, ShellSessionEvent) -> Void
    ) -> Bool {
        guard acceptsSessionStarts, sessions[id] == nil else { return false }
        sessions[id] = Session(onOutput: onOutput, onEvent: onEvent)
        startedSessionIDs.append(id)
        if automaticallyBecomesReady { onEvent(id, .ready(cwd: initialWorkingDirectory)) }
        return true
    }

    @discardableResult
    func submitCommand(_ command: String, to id: ShellSessionID) -> Bool {
        guard acceptsCommands, let session = sessions[id] else { return false }
        submittedCommands.append((id, command))
        session.onEvent(id, .foregroundStarted(command: command))
        return true
    }

    @discardableResult
    func sendInputLine(_ input: String, to id: ShellSessionID) -> Bool {
        guard acceptsInput, sessions[id] != nil else { return false }
        sentInputLines.append((id, input))
        return true
    }

    func interruptForeground(in id: ShellSessionID) {
        guard sessions[id] != nil else { return }
        interruptedSessionIDs.append(id)
    }

    func requestCompletions(
        input: String,
        cursorUTF16: Int,
        in id: ShellSessionID,
        requestID: ShellCompletionRequestID,
        completion: @escaping (ShellSessionID, ShellCompletionResult) -> Void
    ) {
        completionRequests.append(
            CompletionRequest(
                input: input,
                cursorUTF16: cursorUTF16,
                sessionID: id,
                requestID: requestID,
                completion: completion
            )
        )
    }

    func closeSession(_ id: ShellSessionID) {
        guard sessions[id] != nil else { return }
        closedSessionIDs.append(id)
        if automaticallyClosesOnRequest { finishClose(id) }
    }

    func finishClose(_ id: ShellSessionID, result: ScriptRunResult = .success) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        session.onEvent(id, .closed(result))
    }

    func terminateAllImmediately() {
        immediateTerminationCount += 1
    }

    func ready(_ id: ShellSessionID, cwd: String? = nil) {
        sessions[id]?.onEvent(id, .ready(cwd: cwd ?? initialWorkingDirectory))
    }

    func emit(_ id: ShellSessionID, _ output: String) {
        sessions[id]?.onOutput(id, output)
    }

    func finishForeground(
        _ id: ShellSessionID,
        result: ScriptRunResult = .success,
        cwd: String? = nil
    ) {
        sessions[id]?.onEvent(id, .foregroundFinished(result: result, cwd: cwd ?? initialWorkingDirectory))
    }

    func deliverCompletion(
        at index: Int,
        replacementRange: Range<Int>,
        candidates: [String],
        sessionID: ShellSessionID? = nil
    ) {
        let request = completionRequests[index]
        request.completion(
            sessionID ?? request.sessionID,
            ShellCompletionResult(
                requestID: request.requestID,
                replacementRange: replacementRange,
                candidates: candidates
            )
        )
    }
}

/// Model-level shell tests intentionally exercise the same public command path
/// as the search field. Process spawning details have their own runner tests;
/// these assertions pin mode routing, focus, history, and stale-result safety.
final class LauncherModelShellTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-shell-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "LauncherModelShellTests-\(UUID().uuidString)")!
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeModel(
        scriptRunner: ScriptRunning? = nil,
        shellRunner: ShellCommandRunning? = nil,
        shellJobManager: ShellJobManaging? = nil,
        shellSessionManager: PersistentShellSessionManaging? = nil,
        resolvesFileListingsSynchronously: Bool? = nil,
        fileListingResolver: ((FileBrowserSession?, String, URL) -> FileListing?)? = nil
    ) -> LauncherModel {
        let settings = LauncherSettings(defaults: defaults)
        settings.save(scriptsDirectory: directory)
        return LauncherModel(
            settings: settings,
            isUITesting: false,
            loginItems: ShellTestLoginItemService(),
            scriptRunner: scriptRunner,
            shellRunner: shellRunner,
            shellJobManager: shellJobManager,
            shellSessionManager: shellSessionManager,
            browseHome: directory,
            resolvesFileListingsSynchronously: resolvesFileListingsSynchronously,
            fileListingResolver: fileListingResolver,
            scriptDiscoverer: { _ in [] }
        )
    }

    /// `>` is a mode switch, not part of the shell draft. Keep tests going
    /// through the same binding mutation as the AppKit search field.
    private func enterShellMode(_ model: LauncherModel, command: String? = nil) {
        model.query = ">"
        XCTAssertTrue(model.isShellMode)
        XCTAssertEqual(model.query, "", "the trigger must disappear from the visible field")
        if let command { model.query = command }
    }

    func testFirstSubmitLazilyStartsSessionThenRunsWhenReady() throws {
        let manager = StubPersistentShellSessionManager()
        manager.automaticallyBecomesReady = false
        let model = makeModel(shellSessionManager: manager)
        enterShellMode(model, command: "printf lazy")

        model.handleSubmit()

        let id = try XCTUnwrap(manager.startedSessionIDs.first)
        XCTAssertEqual(manager.submittedCommands.count, 0)
        XCTAssertEqual(model.shellRun?.sessionPhase, .starting)
        XCTAssertEqual(model.query, "printf lazy", "draft stays visible until the shell accepts it")

        manager.ready(id, cwd: "/tmp/project")

        XCTAssertEqual(manager.submittedCommands.map(\.1), ["printf lazy"])
        XCTAssertEqual(model.shellRun?.sessionPhase, .foreground)
        XCTAssertEqual(model.shellRun?.workingDirectory, "/tmp/project")
        XCTAssertEqual(model.query, "")
    }

    func testStopClosesAStartingSessionAndLateReadyCannotResurrectIt() throws {
        let manager = StubPersistentShellSessionManager()
        manager.automaticallyBecomesReady = false
        manager.automaticallyClosesOnRequest = false
        let model = makeModel(shellSessionManager: manager)
        enterShellMode(model, command: "blocked startup command")
        model.handleSubmit()
        let id = try XCTUnwrap(manager.startedSessionIDs.first)

        XCTAssertEqual(model.shellRun?.sessionPhase, .starting)
        XCTAssertTrue(model.canStopShellSession)
        XCTAssertTrue(model.hasRunningProcess)

        model.cancelCurrentRun()

        XCTAssertEqual(manager.closedSessionIDs, [id])
        XCTAssertEqual(model.shellRun?.sessionPhase, .closing)
        XCTAssertFalse(model.canStopShellSession)
        XCTAssertFalse(model.hasRunningProcess)

        manager.ready(id, cwd: "/tmp/too-late")
        XCTAssertEqual(model.shellRun?.sessionPhase, .closing)
        XCTAssertTrue(manager.submittedCommands.isEmpty)

        manager.finishClose(id, result: .failedToStart("Shell startup timed out."))
        XCTAssertEqual(model.shellRun?.sessionPhase, .closing)
        model.handleEscape()
        XCTAssertFalse(model.isShellMode)
        XCTAssertEqual(model.runningShellResultCount, 0)
    }

    func testForegroundSubmitSendsStandardInputWithoutStartingAnotherCommand() throws {
        let manager = StubPersistentShellSessionManager()
        let model = makeModel(shellSessionManager: manager)
        enterShellMode(model, command: "claude")
        model.handleSubmit()
        let id = try XCTUnwrap(manager.startedSessionIDs.first)
        XCTAssertEqual(model.shellInputMode, .foreground)

        model.query = "explain this code"
        model.handleSubmit()

        XCTAssertEqual(manager.submittedCommands.map(\.1), ["claude"])
        XCTAssertEqual(manager.sentInputLines.map(\.1), ["explain this code"])
        XCTAssertEqual(manager.sentInputLines.first?.0, id)
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.searchFieldAccessibilityLabel, "Shell standard input")
        XCTAssertTrue(model.searchFieldPlaceholder.contains("claude"))
    }

    func testForegroundCanBeInterruptedRepeatedlyAndReturnsToReadyWithUpdatedDirectory() throws {
        let manager = StubPersistentShellSessionManager()
        let model = makeModel(shellSessionManager: manager)
        enterShellMode(model, command: "sleep 30")
        model.handleSubmit()
        let id = try XCTUnwrap(manager.startedSessionIDs.first)

        model.cancelShellCommand()
        model.cancelShellCommand()

        XCTAssertEqual(manager.interruptedSessionIDs, [id, id])
        manager.finishForeground(id, result: .failure(exitCode: 130), cwd: "/tmp/changed")
        XCTAssertEqual(model.shellRun?.sessionPhase, .ready)
        XCTAssertEqual(model.shellRun?.lastResult, .failure(exitCode: 130))
        XCTAssertEqual(model.shellWorkingDirectoryDisplay, "/tmp/changed")
        XCTAssertEqual(model.shellInputMode, .idle)

        model.query = "/bin/pwd"
        model.handleSubmit()
        XCTAssertEqual(manager.submittedCommands.map(\.1), ["sleep 30", "/bin/pwd"])
        XCTAssertEqual(manager.startedSessionIDs, [id], "the shell session survives foreground interruption")
    }

    func testTabUsesUTF16CaretAndPreservesEmojiAndSuffixWhenCompletionIsAccepted() throws {
        let manager = StubPersistentShellSessionManager()
        let model = makeModel(shellSessionManager: manager)
        let input = "echo 😀 /usr/bin/pri --flag"
        let tokenStart = ("echo 😀 " as NSString).length
        let cursor = ("echo 😀 /usr/bin/pri" as NSString).length
        enterShellMode(model, command: input)

        model.requestShellCompletion(cursorUTF16: cursor)

        let id = try XCTUnwrap(manager.startedSessionIDs.first)
        XCTAssertEqual(manager.completionRequests.count, 1)
        XCTAssertEqual(manager.completionRequests[0].input, input)
        XCTAssertEqual(manager.completionRequests[0].cursorUTF16, cursor)
        manager.deliverCompletion(
            at: 0,
            replacementRange: tokenStart..<cursor,
            candidates: ["/usr/bin/printenv", "/usr/bin/printf"]
        )
        XCTAssertEqual(model.shellCompletions, ["/usr/bin/printenv", "/usr/bin/printf"])
        XCTAssertEqual(model.shellCompletionSelectionIndex, 0)

        model.moveShellCompletion(by: 1)
        model.acceptShellCompletion()

        XCTAssertEqual(model.query, "echo 😀 /usr/bin/printf --flag")
        XCTAssertEqual(
            model.shellCompletionCaretUTF16,
            tokenStart + ("/usr/bin/printf" as NSString).length
        )
        XCTAssertEqual(model.shellCompletionCaretRequestToken, 1)
        XCTAssertTrue(model.shellCompletions.isEmpty)
        XCTAssertEqual(manager.startedSessionIDs, [id])
        XCTAssertTrue(manager.submittedCommands.isEmpty, "accepting completion must not execute it")
    }

    func testStaleCompletionCannotReplaceNewerDraft() {
        let manager = StubPersistentShellSessionManager()
        let model = makeModel(shellSessionManager: manager)
        enterShellMode(model, command: "git che")
        model.requestShellCompletion()
        XCTAssertEqual(manager.completionRequests.count, 1)

        model.query = "git status"
        manager.deliverCompletion(at: 0, replacementRange: 4..<7, candidates: ["checkout"])

        XCTAssertEqual(model.query, "git status")
        XCTAssertTrue(model.shellCompletions.isEmpty)
    }

    func testEscapeDismissesCompletionBeforeLeavingPersistentShell() {
        let manager = StubPersistentShellSessionManager()
        let model = makeModel(shellSessionManager: manager)
        enterShellMode(model, command: "git che")
        model.requestShellCompletion()
        manager.deliverCompletion(at: 0, replacementRange: 4..<7, candidates: ["checkout"])
        XCTAssertFalse(model.shellCompletions.isEmpty)

        model.handleEscape()

        XCTAssertTrue(model.isShellMode)
        XCTAssertTrue(model.shellCompletions.isEmpty)
        XCTAssertEqual(model.query, "git che")

        model.handleEscape()
        XCTAssertFalse(model.isShellMode)
    }

    func testReadyAndForegroundBackgroundSessionsStayPinnedUntilClosed() throws {
        let manager = StubPersistentShellSessionManager()
        let model = makeModel(shellSessionManager: manager)
        enterShellMode(model, command: "first")
        model.handleSubmit()
        let firstID = try XCTUnwrap(manager.startedSessionIDs.first)
        manager.finishForeground(firstID, cwd: "/tmp/first")
        model.handleEscape()

        enterShellMode(model, command: "second")
        model.handleSubmit()
        let secondID = try XCTUnwrap(manager.startedSessionIDs.last)
        model.handleEscape()

        XCTAssertEqual(model.runningShellResultCount, 2)
        XCTAssertEqual(model.results.prefix(2).map(\.kind), [.runningShell, .runningShell])
        XCTAssertEqual(manager.activeSessionIDs, [firstID, secondID])

        manager.closeSession(firstID)
        XCTAssertEqual(model.runningShellResultCount, 1)
        XCTAssertEqual(model.results.first?.kind, .runningShell)
    }

    func testLiteralLeadingGreaterThanRoutesRawCommandToTheShell() {
        let runner = StubShellRunner()
        let model = makeModel(shellRunner: runner)
        let rawCommand = "printf '%s' 'alpha | beta > gamma'"
        enterShellMode(model, command: rawCommand)

        XCTAssertTrue(model.isShellMode)
        XCTAssertTrue(model.isPanelExpanded)
        XCTAssertTrue(model.results.isEmpty)

        model.handleSubmit()

        XCTAssertEqual(runner.commands, [rawCommand])
        XCTAssertEqual(model.shellRun?.command, rawCommand)
        XCTAssertEqual(model.shellRun?.phase, .running)
        XCTAssertEqual(model.shellRun?.output, "$ \(rawCommand)\n")
        XCTAssertEqual(model.query, "", "the console should be ready for another command")
    }

    func testPastedLeadingTriggerIsConsumedWithOneOptionalSeparator() {
        let model = makeModel(shellRunner: StubShellRunner())

        model.query = "> printf pasted"

        XCTAssertTrue(model.isShellMode)
        XCTAssertEqual(model.query, "printf pasted")
        XCTAssertFalse(model.query.contains(">"), "the trigger must not remain in visible input")
    }

    func testSeparatelyTypedPromptSpaceIsConsumedAfterBareTrigger() {
        let model = makeModel(shellRunner: StubShellRunner())

        model.query = ">"
        XCTAssertEqual(model.query, "")
        model.query = " "

        XCTAssertTrue(model.isShellMode)
        XCTAssertEqual(model.query, "", "the optional prompt separator must not become command input")

        model.query = "echo ready"
        XCTAssertEqual(model.query, "echo ready")
    }

    func testTriggerWithoutSeparatorIsConsumedFromPastedCommand() {
        let model = makeModel(shellRunner: StubShellRunner())

        model.query = ">printf compact"

        XCTAssertTrue(model.isShellMode)
        XCTAssertEqual(model.query, "printf compact")
    }

    func testOnlyOneOptionalSeparatorIsConsumedWithTrigger() {
        let model = makeModel(shellRunner: StubShellRunner())

        model.query = ">  printf intentional-leading-space"

        XCTAssertTrue(model.isShellMode)
        XCTAssertEqual(model.query, " printf intentional-leading-space")
    }

    func testLeadingGreaterThanInsideShellModeIsRawCommandInputNotAnotherTrigger() {
        let model = makeModel(shellRunner: StubShellRunner())
        enterShellMode(model)

        model.query = "> output.txt"

        XCTAssertTrue(model.isShellMode)
        XCTAssertEqual(model.query, "> output.txt")
    }

    func testGreaterThanAfterWhitespaceRemainsOrdinarySearchInput() {
        let runner = StubShellRunner()
        let model = makeModel(shellRunner: runner)
        model.query = " > echo ordinary-search"

        model.handleSubmit()

        XCTAssertFalse(model.isShellMode)
        XCTAssertFalse(model.isPanelExpanded)
        XCTAssertTrue(runner.commands.isEmpty)
        XCTAssertEqual(model.query, " > echo ordinary-search")
    }

    func testShellDraftPreservesCommandWhitespaceAfterTheTriggerWasConsumed() {
        let runner = StubShellRunner()
        let model = makeModel(shellRunner: runner)
        enterShellMode(model, command: "  printf spacing")

        model.handleSubmit()

        XCTAssertEqual(runner.commands, [" printf spacing"])
        XCTAssertEqual(model.shellRun?.command, " printf spacing")
    }

    func testEmptyShellPromptDoesNotStartOrResetAnything() {
        let runner = StubShellRunner()
        let model = makeModel(shellRunner: runner)
        enterShellMode(model, command: "   ")
        let focusToken = model.focusToken

        model.handleSubmit()

        XCTAssertEqual(model.query, "  ")
        XCTAssertEqual(model.focusToken, focusToken)
        XCTAssertTrue(runner.commands.isEmpty)
        XCTAssertNil(model.shellRun)
    }

    func testSubmitKeepsSearchFocusedAndAddsOnlyInMemoryHistory() {
        let runner = StubShellRunner()
        let model = makeModel(shellRunner: runner)
        let submitted = "printf history-entry"
        model.focus(.argument(0))
        enterShellMode(model, command: submitted)

        model.handleSubmit()

        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.focusTarget, .search)
        runner.finish(.success)

        model.moveSelection(by: -1)
        XCTAssertEqual(model.query, submitted)
        model.moveSelection(by: 1)
        XCTAssertEqual(model.query, "")

        let freshModel = makeModel(shellRunner: StubShellRunner())
        enterShellMode(freshModel)
        freshModel.moveSelection(by: -1)
        XCTAssertEqual(freshModel.query, "", "shell history must not persist across model sessions")
    }

    func testShellHistoryRetainsOnlyTheMostRecentFiftyCommands() {
        let runner = StubShellRunner()
        let model = makeModel(shellRunner: runner)
        enterShellMode(model)
        for index in 0..<55 {
            model.query = "command-\(index)"
            model.handleSubmit()
            runner.finish(.success)
        }

        for _ in 0..<55 { model.moveSelection(by: -1) }

        XCTAssertEqual(model.query, "command-5")
    }

    func testEscapeLeavesShellModeBeforeClosingTheLauncher() {
        let model = makeModel(shellRunner: StubShellRunner())
        var closeRequests = 0
        model.onRequestClose = { closeRequests += 1 }
        enterShellMode(model, command: "echo not-submitted")

        model.handleEscape()

        XCTAssertEqual(model.query, "")
        XCTAssertFalse(model.isShellMode)
        XCTAssertEqual(closeRequests, 0)

        model.handleEscape()
        XCTAssertEqual(closeRequests, 1)
    }

    func testEscapeFromSettingsReturnsToTheShellConsoleWithoutClearingItsDraft() {
        let model = makeModel(shellRunner: StubShellRunner())
        enterShellMode(model, command: "echo draft")
        model.showSettings()

        model.handleEscape()

        XCTAssertEqual(model.screen, .search)
        XCTAssertEqual(model.query, "echo draft")
        XCTAssertEqual(model.panelPresentation, .shellConsole)
    }

    func testEscapeDoesNotCancelACommandThatIsAlreadyRunning() throws {
        let manager = StubShellJobManager()
        let model = makeModel(shellJobManager: manager)
        enterShellMode(model, command: "sleep 30")
        model.handleSubmit()
        let id = try XCTUnwrap(manager.commands.first?.id)

        model.handleEscape()

        XCTAssertEqual(model.query, "")
        XCTAssertFalse(model.isShellMode)
        XCTAssertTrue(manager.cancelledIDs.isEmpty)
        XCTAssertEqual(manager.activeJobIDs, [id])
        XCTAssertEqual(model.shellSessions.first { $0.id == id }?.phase, .running)
        XCTAssertNil(model.shellRun, "an escaped background shell must not remain the displayed run")
        XCTAssertNil(model.displayedRunPhase)
        manager.finish(id, result: .success)
    }

    func testEscapedRunningShellAppearsBeforeNormalResultsAndCanBeResumed() throws {
        let manager = StubShellJobManager()
        let model = makeModel(shellJobManager: manager)
        enterShellMode(model, command: "sleep 30")
        model.handleSubmit()
        let id = try XCTUnwrap(manager.commands.first?.id)

        model.handleEscape()

        XCTAssertFalse(model.isShellMode)
        XCTAssertEqual(manager.activeJobIDs, [id])
        XCTAssertNil(model.shellRun)
        let runningShell = try XCTUnwrap(model.results.first)
        XCTAssertEqual(runningShell.kind, .runningShell)
        guard case .shellSession = runningShell.destination else {
            return XCTFail("running shell result must resume a session, got \(runningShell.destination)")
        }
        XCTAssertTrue(runningShell.title.contains("sleep 30"), runningShell.title)
        XCTAssertEqual(model.runningShellResultCount, 1)
        XCTAssertEqual(
            model.results.dropFirst().first?.title,
            "Launcher Settings",
            "the running shell must be pinned ahead of normal results"
        )

        model.query = "ordinary-filter"
        XCTAssertEqual(model.results.first?.kind, .runningShell)
        XCTAssertEqual(model.runningShellResultCount, 1)
        model.query = ""

        model.select(index: 0)
        model.handleSubmit()

        XCTAssertTrue(model.isShellMode)
        XCTAssertTrue(model.isPanelExpanded)
        XCTAssertEqual(model.panelPresentation, .shellConsole)
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(
            manager.commands.map(\.command),
            ["sleep 30"],
            "resuming must not launch a second process"
        )
        XCTAssertEqual(model.shellRun?.phase, .running)
        manager.finish(id, result: .success)
    }

    func testEscapedBackgroundShellDoesNotBlockLauncherScripts() throws {
        let manager = StubShellJobManager()
        let scriptRunner = StubAcceptingScriptRunner()
        let model = makeModel(scriptRunner: scriptRunner, shellJobManager: manager)
        enterShellMode(model, command: "sleep 30")
        model.handleSubmit()
        let shellID = try XCTUnwrap(manager.commands.first?.id)
        model.handleEscape()

        let script = ScriptCommand(
            id: "parallel-script",
            url: directory.appendingPathComponent("parallel.sh"),
            title: "Parallel Script",
            mode: .normal,
            packageName: nil,
            description: nil,
            needsConfirmation: false,
            arguments: []
        )
        model.activate(
            LauncherItem(
                id: "script.parallel-script",
                title: script.title,
                subtitle: nil,
                kind: .scriptCommand,
                destination: .script(script),
                keywords: ""
            )
        )

        XCTAssertEqual(scriptRunner.command, script)
        XCTAssertEqual(model.scriptRun?.phase, .running)
        XCTAssertEqual(manager.activeJobIDs, [shellID])
        XCTAssertFalse(model.isRunPalettePresented)

        scriptRunner.finish(.success)
        manager.finish(shellID, result: .success)
    }

    func testConcurrentRunningShellsArePinnedTogetherWithDistinctResumeDestinations() throws {
        let manager = StubShellJobManager()
        let model = makeModel(shellJobManager: manager)
        enterShellMode(model, command: "first-long-command")
        model.handleSubmit()
        let firstID = try XCTUnwrap(manager.commands.first?.id)
        model.handleEscape()
        manager.emit(firstID, "first-output")

        enterShellMode(model, command: "second-long-command")
        model.handleSubmit()
        let secondID = try XCTUnwrap(manager.commands.last?.id)
        model.handleEscape()
        manager.emit(secondID, "second-output")

        XCTAssertEqual(manager.commands.map(\.command), ["first-long-command", "second-long-command"])
        XCTAssertEqual(manager.activeJobIDs, [firstID, secondID])
        XCTAssertEqual(model.runningShellResultCount, 2)
        XCTAssertEqual(model.results.prefix(2).map(\.kind), [.runningShell, .runningShell])
        XCTAssertEqual(model.results.dropFirst(2).first?.title, "Launcher Settings")

        let destinations = model.results.prefix(2).map(\.destination)
        for destination in destinations {
            guard case .shellSession = destination else {
                return XCTFail("running shell row must resume a session, got \(destination)")
            }
        }
        XCTAssertNotEqual(
            destinations[0],
            destinations[1],
            "each row must resume its own process"
        )

        let firstIndex = try XCTUnwrap(model.results.firstIndex { $0.title.contains("first-long-command") })
        model.select(index: firstIndex)
        model.handleSubmit()
        XCTAssertTrue(model.isShellMode)
        XCTAssertEqual(model.shellRun?.command, "first-long-command")
        XCTAssertTrue(model.shellRun?.output.contains("first-output") == true)
        XCTAssertFalse(model.shellRun?.output.contains("second-output") == true)
        XCTAssertEqual(manager.commands.count, 2, "resume must not launch another command")

        model.handleEscape()
        let secondIndex = try XCTUnwrap(model.results.firstIndex { $0.title.contains("second-long-command") })
        model.select(index: secondIndex)
        model.handleSubmit()
        XCTAssertEqual(model.shellRun?.command, "second-long-command")
        XCTAssertTrue(model.shellRun?.output.contains("second-output") == true)
        XCTAssertFalse(model.shellRun?.output.contains("first-output") == true)

        manager.finish(firstID, result: .success)
        manager.finish(secondID, result: .success)
    }

    func testCompletedShellIsNotPinnedAsARunningSessionAfterLeavingConsole() throws {
        let manager = StubShellJobManager()
        let model = makeModel(shellJobManager: manager)
        enterShellMode(model, command: "true")
        model.handleSubmit()
        let id = try XCTUnwrap(manager.commands.first?.id)
        model.handleEscape()

        XCTAssertFalse(model.isShellMode)
        XCTAssertEqual(model.results.first?.kind, .runningShell)

        manager.finish(id, result: .success)

        XCTAssertEqual(model.results.first?.title, "Launcher Settings")
        XCTAssertFalse(model.results.contains { $0.title.contains("true") })
    }

    func testOutputAcrossChunksAndCompletionPublishesTranscriptAndStatus() throws {
        let manager = StubShellJobManager()
        let model = makeModel(shellJobManager: manager)
        enterShellMode(model, command: "colorful")
        model.handleSubmit()
        let id = try XCTUnwrap(manager.commands.first?.id)

        manager.emit(id, "before ")
        manager.emit(id, "red")
        XCTAssertEqual(model.shellRun?.output, "$ colorful\nbefore red")

        manager.finish(id, result: .failure(exitCode: 23))

        XCTAssertEqual(model.shellRun?.output, "$ colorful\nbefore red")
        XCTAssertEqual(model.shellRun?.phase, .finished(.failure(exitCode: 23)))
        XCTAssertFalse(model.shellRun?.didTruncateOutput ?? true)
    }

    func testConsecutiveCommandsAppendToOneConsoleTranscript() throws {
        let manager = StubShellJobManager()
        let model = makeModel(shellJobManager: manager)
        enterShellMode(model, command: "first")
        model.handleSubmit()
        let firstID = try XCTUnwrap(manager.commands.first?.id)
        manager.emit(firstID, "one\n")
        manager.finish(firstID, result: .success)

        model.query = "second"
        model.handleSubmit()
        let secondID = try XCTUnwrap(manager.commands.last?.id)
        manager.emit(secondID, "two\n")
        manager.finish(secondID, result: .success)

        XCTAssertEqual(manager.commands.map(\.command), ["first", "second"])
        XCTAssertEqual(model.shellRun?.command, "second")
        XCTAssertEqual(model.shellRun?.phase, .finished(.success))
        XCTAssertEqual(model.shellRun?.output, "$ first\none\n\n$ second\ntwo\n")
    }

    func testCancelDelegatesToJobManagerAndRecordsCancelledStatus() throws {
        let manager = StubShellJobManager()
        let model = makeModel(shellJobManager: manager)
        enterShellMode(model, command: "long-running")
        model.handleSubmit()
        let id = try XCTUnwrap(manager.commands.first?.id)

        model.cancelShellCommand()

        XCTAssertEqual(manager.cancelledIDs, [id])
        XCTAssertFalse(manager.isRunning)
        XCTAssertEqual(model.shellRun?.phase, .finished(.cancelled))
    }

    func testTranscriptRetainsTailAndMarksEarlierOutputAsTruncated() throws {
        let manager = StubShellJobManager()
        let model = makeModel(shellJobManager: manager)
        enterShellMode(model, command: "noisy")
        model.handleSubmit()
        let id = try XCTUnwrap(manager.commands.first?.id)

        manager.emit(id, String(repeating: "x", count: 110_000) + "tail")

        let run = model.shellRun
        XCTAssertTrue(run?.didTruncateOutput == true)
        XCTAssertLessThanOrEqual(run?.output.count ?? Int.max, 100_000)
        XCTAssertTrue(run?.output.hasPrefix("[earlier output truncated]\n") == true)
        XCTAssertTrue(run?.output.hasSuffix("tail") == true)
        manager.finish(id, result: .success)
    }

    func testRejectedConcurrentSubmissionPreservesTheActiveRunAndNewInput() throws {
        let manager = StubShellJobManager()
        let model = makeModel(shellJobManager: manager)
        enterShellMode(model, command: "first-command")
        model.handleSubmit()
        let id = try XCTUnwrap(manager.commands.first?.id)
        manager.emit(id, "still running")
        manager.acceptsRuns = false

        model.query = "second-command"
        model.handleSubmit()

        XCTAssertEqual(manager.commands.map(\.command), ["first-command"])
        XCTAssertEqual(model.shellRun?.command, "first-command")
        XCTAssertEqual(model.shellRun?.output, "$ first-command\nstill running")
        XCTAssertEqual(model.shellRun?.phase, .running)
        XCTAssertEqual(model.query, "second-command")
        manager.finish(id, result: .success)
    }

    func testActiveScriptPreventsShellSubmissionWithoutDiscardingInput() {
        let shellRunner = StubShellRunner()
        let model = makeModel(
            scriptRunner: StubBusyScriptRunner(),
            shellRunner: shellRunner
        )
        enterShellMode(model, command: "waits-for-script")

        model.handleSubmit()

        XCTAssertTrue(shellRunner.commands.isEmpty)
        XCTAssertNil(model.shellRun)
        XCTAssertEqual(model.query, "waits-for-script")
        XCTAssertTrue(model.isRunPalettePresented)
    }

    func testShellModeDrivesExpandedPresentationCallbackWithoutOpeningOutputDrawer() {
        let model = makeModel(shellRunner: StubShellRunner())
        var expandedStates: [Bool] = []
        model.onOutputPanePresentationChange = { expandedStates.append($0) }

        enterShellMode(model)
        XCTAssertTrue(model.isPanelExpanded)
        XCTAssertFalse(model.isOutputPanePresented)

        model.handleEscape()
        XCTAssertFalse(model.isPanelExpanded)
        XCTAssertEqual(expandedStates, [true, false])
    }

    func testSwitchingFromOutputDrawerToShellConsoleDoesNotResizeTwice() {
        let model = makeModel(shellRunner: StubShellRunner())
        var expandedStates: [Bool] = []
        model.onOutputPanePresentationChange = { expandedStates.append($0) }
        model.toggleOutputPane()
        XCTAssertEqual(model.panelPresentation, .outputDrawer)

        enterShellMode(model)

        XCTAssertEqual(model.panelPresentation, .shellConsole)
        XCTAssertEqual(expandedStates, [true], "expanded-to-expanded must not resize the panel")

        model.handleEscape()
        XCTAssertEqual(expandedStates, [true, false])
    }

    func testLateFileListingCannotReplaceShellConsole() {
        let listingStarted = expectation(description: "listing started")
        let releaseListing = DispatchSemaphore(value: 0)
        defer { releaseListing.signal() }
        let model = makeModel(
            shellRunner: StubShellRunner(),
            resolvesFileListingsSynchronously: false,
            fileListingResolver: { _, _, home in
                listingStarted.fulfill()
                releaseListing.wait()
                return FileListing(
                    directory: home,
                    iCloudEntry: nil,
                    directories: [],
                    files: [
                        FileEntry(
                            url: home.appendingPathComponent("stale.txt"),
                            name: "stale.txt",
                            isDirectory: false,
                            permissions: "644"
                        )
                    ],
                    error: nil,
                    isTruncated: false
                )
            }
        )

        model.query = "~/"
        wait(for: [listingStarted], timeout: 2)
        enterShellMode(model, command: "echo current")
        releaseListing.signal()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(model.query, "echo current")
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertNil(model.calculation)
        XCTAssertNil(model.fileListing)
        XCTAssertFalse(model.isFileBrowsing)
    }
}
