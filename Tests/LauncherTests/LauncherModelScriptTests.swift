import XCTest
@testable import Launcher

private final class QuietLoginItemService: LoginItemService {
    var isEnabled = false
    func setEnabled(_ enabled: Bool) throws { isEnabled = enabled }
}

/// Deterministic runner for branches that are awkward with real processes.
private final class StubScriptRunner: ScriptRunning {
    var isRunning = false
    private(set) var lastCommand: ScriptCommand?
    private(set) var lastArguments: [String] = []
    private var onOutput: ((String) -> Void)?
    private var onCompletion: ((ScriptRunResult) -> Void)?

    func run(
        _ command: ScriptCommand,
        arguments: [String],
        onOutput: @escaping (String) -> Void,
        onCompletion: @escaping (ScriptRunResult) -> Void
    ) -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        lastCommand = command
        lastArguments = arguments
        self.onOutput = onOutput
        self.onCompletion = onCompletion
        return true
    }

    func cancel() {
        finish(.cancelled)
    }

    func emit(_ chunk: String) { onOutput?(chunk) }

    func finish(_ result: ScriptRunResult) {
        guard isRunning else { return }
        isRunning = false
        onCompletion?(result)
    }
}

final class LauncherModelScriptTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-script-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "LauncherModelScriptTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func writeScript(_ name: String, header: String, body: String) throws {
        let url = directory.appendingPathComponent(name)
        try "#!/bin/sh\n\(header)\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func makeModel(runner: ScriptRunning? = nil) -> LauncherModel {
        let settings = LauncherSettings(defaults: defaults)
        settings.save(scriptsDirectory: directory)
        let model = LauncherModel(
            settings: settings,
            isUITesting: false,
            loginItems: QuietLoginItemService(),
            scriptRunner: runner
        )
        return model
    }

    private func waitForScripts(in model: LauncherModel, query: String, timeout: TimeInterval = 5) {
        model.rescanScripts()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            model.query = query
            if model.results.contains(where: { $0.kind == .scriptCommand }) { return }
            model.query = ""
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("scripts never appeared for query \(query)")
    }

    private func waitUntil(
        _ timeout: TimeInterval = 8,
        _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(condition())
    }

    func testScriptAppearsInSearchResults() throws {
        try writeScript("hello.sh", header: "# @raycast.title Greet World\n# @raycast.packageName Demo", body: "echo hi")
        let model = makeModel()

        waitForScripts(in: model, query: "greet")

        let item = model.results.first { $0.kind == .scriptCommand }
        XCTAssertEqual(item?.title, "Greet World")
        XCTAssertEqual(item?.subtitle, "Demo")
    }

    func testCreateScriptCommandItemIsSearchable() {
        let model = makeModel()
        model.query = "create script"
        XCTAssertTrue(model.results.contains { $0.destination == .createScript })
    }

    func testCompactRunLifecycle() throws {
        try writeScript("count.sh", header: "# @raycast.title Counter\n# @raycast.mode compact", body: "echo line1\necho line2")
        let model = makeModel()
        waitForScripts(in: model, query: "counter")
        model.select(index: model.results.firstIndex { $0.kind == .scriptCommand }!)

        model.handleSubmit()

        XCTAssertEqual(model.scriptRun?.phase, .running)
        XCTAssertTrue(model.isRunChipVisible)
        XCTAssertFalse(model.isOutputExpanded)

        waitUntil { model.scriptRun?.phase == .finished(.success) }
        XCTAssertTrue(model.scriptRun?.output.contains("line1") == true)
        XCTAssertTrue(model.scriptRun?.output.contains("line2") == true)
        XCTAssertTrue(model.showMoreAvailable)

        model.query = "something else"
        XCTAssertNil(model.scriptRun)
        XCTAssertFalse(model.isRunChipVisible)
    }

    func testFullOutputModeExpandsImmediately() throws {
        try writeScript("full.sh", header: "# @raycast.title Full Runner\n# @raycast.mode fullOutput", body: "echo out")
        let model = makeModel()
        waitForScripts(in: model, query: "full runner")
        model.select(index: model.results.firstIndex { $0.kind == .scriptCommand }!)

        model.handleSubmit()

        XCTAssertTrue(model.isOutputExpanded)
        waitUntil { model.scriptRun?.phase == .finished(.success) }
    }

    func testSilentModeRequestsClose() throws {
        try writeScript("quiet.sh", header: "# @raycast.title Quiet One\n# @raycast.mode silent", body: "echo shh")
        let model = makeModel()
        var closed = false
        model.onRequestClose = { closed = true }
        waitForScripts(in: model, query: "quiet")
        model.select(index: model.results.firstIndex { $0.kind == .scriptCommand }!)

        model.handleSubmit()

        XCTAssertTrue(closed)
        XCTAssertFalse(model.showMoreAvailable)
        waitUntil { model.scriptRun?.phase == .finished(.success) }
    }

    func testNeedsConfirmationFlow() throws {
        try writeScript("danger.sh", header: "# @raycast.title Danger Zone\n# @raycast.needsConfirmation true", body: "echo boom")
        let model = makeModel()
        waitForScripts(in: model, query: "danger")
        model.select(index: model.results.firstIndex { $0.kind == .scriptCommand }!)

        model.handleSubmit()
        XCTAssertNotNil(model.pendingRun)
        XCTAssertNil(model.scriptRun)

        model.handleEscape()
        XCTAssertNil(model.pendingRun)
        XCTAssertNil(model.scriptRun)

        model.handleSubmit()
        model.confirmPendingRun()
        XCTAssertNotNil(model.scriptRun)
        waitUntil { model.scriptRun?.phase == .finished(.success) }
        XCTAssertTrue(model.scriptRun?.output.contains("boom") == true)
    }

    func testRequiredArgumentGateAndPassing() throws {
        try writeScript(
            "arg.sh",
            header: "# @raycast.title Args Needed\n# @raycast.argument1 { \"placeholder\": \"Name\" }",
            body: "echo \"got:$1\""
        )
        let model = makeModel()
        waitForScripts(in: model, query: "args needed")
        model.select(index: model.results.firstIndex { $0.kind == .scriptCommand }!)

        model.handleSubmit()
        XCTAssertNil(model.scriptRun, "run must be blocked while required argument is empty")
        XCTAssertEqual(model.focusTarget, .argument(0))

        model.argumentValues[0] = "World"
        model.handleSubmit()
        waitUntil { model.scriptRun?.phase == .finished(.success) }
        XCTAssertTrue(model.scriptRun?.output.contains("got:World") == true)
    }

    func testFocusCycleWithTwoArguments() throws {
        try writeScript(
            "two.sh",
            header: "# @raycast.title Two Args\n# @raycast.argument1 { \"placeholder\": \"A\" }\n# @raycast.argument2 { \"placeholder\": \"B\" }",
            body: "echo hi"
        )
        let model = makeModel()
        waitForScripts(in: model, query: "two args")
        model.select(index: model.results.firstIndex { $0.kind == .scriptCommand }!)
        XCTAssertEqual(model.argumentValues.count, 2)

        XCTAssertEqual(model.focusTarget, .search)
        model.handleFocusNext()
        XCTAssertEqual(model.focusTarget, .argument(0))
        model.handleFocusNext()
        XCTAssertEqual(model.focusTarget, .argument(1))
        model.handleFocusNext()
        XCTAssertEqual(model.focusTarget, .search)
        model.handleFocusPrevious()
        XCTAssertEqual(model.focusTarget, .argument(1))

        model.handleFocusNext()
        model.handleEscape()
        XCTAssertEqual(model.focusTarget, .search)
    }

    func testEscapeLeavesCreateScriptScreenDespiteStaleArgumentFocus() throws {
        try writeScript(
            "focus-edit.sh",
            header: "# @raycast.title Focus Edit\n# @raycast.argument1 { \"placeholder\": \"Name\" }",
            body: "echo hi"
        )
        let model = makeModel()
        waitForScripts(in: model, query: "focus edit")
        model.select(index: model.results.firstIndex { $0.kind == .scriptCommand }!)
        model.focus(.argument(0))
        XCTAssertEqual(model.focusTarget, .argument(0))

        model.beginEditingSelectedScript()
        XCTAssertEqual(model.screen, .createScript)

        model.handleEscape()

        XCTAssertEqual(
            model.screen, .search,
            "a single escape must leave the create/edit screen even though focusTarget is stale from the search screen"
        )
    }

    func testToggleActionsIgnoredWhilePendingRunConfirmationIsUp() throws {
        try writeScript(
            "confirm.sh",
            header: "# @raycast.title Confirm Me\n# @raycast.needsConfirmation true",
            body: "echo hi"
        )
        let model = makeModel()
        waitForScripts(in: model, query: "confirm me")
        model.select(index: model.results.firstIndex { $0.kind == .scriptCommand }!)

        model.handleSubmit()
        XCTAssertNotNil(model.pendingRun)

        model.toggleActions()

        XCTAssertFalse(model.isActionsPresented, "the actions palette must not open behind a pending confirmation")
    }

    func testBusyRunnerRejectsSecondRunAndShowsPalette() throws {
        try writeScript("a.sh", header: "# @raycast.title Alpha Script\n# @raycast.mode compact", body: "echo a")
        let runner = StubScriptRunner()
        let model = makeModel(runner: runner)
        waitForScripts(in: model, query: "alpha")
        model.select(index: model.results.firstIndex { $0.kind == .scriptCommand }!)

        model.handleSubmit()
        XCTAssertEqual(model.scriptRun?.phase, .running)
        let firstCommand = runner.lastCommand

        model.handleSubmit() // second run while busy
        XCTAssertTrue(model.isRunPalettePresented)
        XCTAssertEqual(runner.lastCommand?.id, firstCommand?.id, "second run must not start")

        model.cancelScriptRun()
        XCTAssertEqual(model.scriptRun?.phase, .finished(.cancelled))
    }

    func testFailedToStartSurfacesAsFinishedFailure() throws {
        try writeScript("b.sh", header: "# @raycast.title Beta Script\n# @raycast.mode compact", body: "echo b")
        let runner = StubScriptRunner()
        let model = makeModel(runner: runner)
        waitForScripts(in: model, query: "beta")
        model.select(index: model.results.firstIndex { $0.kind == .scriptCommand }!)

        model.handleSubmit()
        runner.emit("partial")
        runner.finish(.failedToStart("nope"))

        XCTAssertEqual(model.scriptRun?.phase, .finished(.failedToStart("nope")))
        XCTAssertEqual(model.scriptRun?.output, "partial")
    }

    func testEscapePrecedenceOutputPanelBeforeClose() throws {
        try writeScript("c.sh", header: "# @raycast.title Gamma Script\n# @raycast.mode fullOutput", body: "echo c")
        let model = makeModel(runner: StubScriptRunner())
        var closed = false
        model.onRequestClose = { closed = true }
        waitForScripts(in: model, query: "gamma")
        model.select(index: model.results.firstIndex { $0.kind == .scriptCommand }!)

        model.handleSubmit()
        XCTAssertTrue(model.isOutputExpanded)

        model.toggleRunPalette()
        XCTAssertTrue(model.isRunPalettePresented)
        model.handleEscape()
        XCTAssertFalse(model.isRunPalettePresented)
        XCTAssertTrue(model.isOutputExpanded)

        model.handleEscape()
        XCTAssertFalse(model.isOutputExpanded)
        XCTAssertFalse(closed)

        model.handleEscape()
        XCTAssertTrue(closed)
    }

    // Mirrors the VM UI test's exact path through the isUITesting fixtures.
    func testUITestingFixtureFlowRunsCountLines() {
        let model = LauncherModel(
            settings: LauncherSettings(defaults: defaults),
            isUITesting: true,
            loginItems: QuietLoginItemService()
        )
        model.loadApplications()
        var closed = false
        model.onRequestClose = { closed = true }

        model.query = "count"
        XCTAssertEqual(model.results.first?.title, "Count Lines")
        XCTAssertEqual(model.results.first?.kind, .scriptCommand)
        XCTAssertEqual(model.selectedIndex, 0)

        model.handleSubmit()

        XCTAssertEqual(model.scriptRun?.phase, .running)
        XCTAssertTrue(model.isRunChipVisible)
        XCTAssertFalse(closed, "compact run must not close the launcher")

        waitUntil(10) { model.scriptRun?.phase == .finished(.success) }
        XCTAssertTrue(model.scriptRun?.output.contains("line 3") == true)
    }

    func testCreateScriptEndState() {
        let model = makeModel()
        model.scriptDraft.title = "Fresh Command"
        model.scriptDraft.mode = .inline

        model.saveScriptDraft(andOpen: false)

        XCTAssertEqual(model.screen, .search)
        XCTAssertEqual(model.query, "Fresh Command")
        XCTAssertNil(model.createScriptError)
        let created = directory.appendingPathComponent("fresh-command.sh")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: created.path))
        XCTAssertTrue(model.results.contains { $0.title == "Fresh Command" && $0.kind == .scriptCommand })
    }

    func testScriptActionsIncludeEditAndDelete() throws {
        try writeScript("act.sh", header: "# @raycast.title Actionable", body: "echo hi")
        let model = makeModel()
        waitForScripts(in: model, query: "actionable")
        model.select(index: model.results.firstIndex { $0.kind == .scriptCommand }!)

        XCTAssertEqual(
            model.availableActions,
            [.open, .editScript, .showInFinder, .copyScriptContents, .deleteScript]
        )
    }

    func testEditScriptActionOpensPrefilledForm() throws {
        try writeScript(
            "edit-me.sh",
            header: "# @raycast.title Edit Me\n# @raycast.mode inline\n# @raycast.packageName Tools\n# @raycast.description Tweak things\n# @raycast.argument1 { \"placeholder\": \"Target\" }",
            body: "echo edit"
        )
        let model = makeModel()
        waitForScripts(in: model, query: "edit me")
        model.select(index: model.results.firstIndex { $0.kind == .scriptCommand }!)

        model.perform(.editScript)

        XCTAssertEqual(model.screen, .createScript)
        XCTAssertEqual(
            model.editingScriptURL?.resolvingSymlinksInPath(),
            directory.appendingPathComponent("edit-me.sh").resolvingSymlinksInPath()
        )
        XCTAssertEqual(model.scriptDraft.title, "Edit Me")
        XCTAssertEqual(model.scriptDraft.mode, .inline)
        XCTAssertEqual(model.scriptDraft.packageName, "Tools")
        XCTAssertEqual(model.scriptDraft.description, "Tweak things")
        XCTAssertEqual(model.scriptDraft.argumentPlaceholders, ["Target"])
    }

    func testSaveEditedScriptRewritesFileAndReturnsToSearch() throws {
        try writeScript("rename.sh", header: "# @raycast.title Old Name\n# @raycast.mode compact", body: "echo body-stays")
        let model = makeModel()
        waitForScripts(in: model, query: "old name")
        model.select(index: model.results.firstIndex { $0.kind == .scriptCommand }!)

        model.perform(.editScript)
        model.scriptDraft.title = "New Name"
        model.scriptDraft.mode = .silent
        model.saveScriptDraft(andOpen: false)

        XCTAssertEqual(model.screen, .search)
        XCTAssertEqual(model.query, "New Name")
        XCTAssertNil(model.editingScriptURL)
        XCTAssertNil(model.createScriptError)
        XCTAssertTrue(model.results.contains { $0.title == "New Name" && $0.kind == .scriptCommand })

        let url = directory.appendingPathComponent("rename.sh")
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("echo body-stays"), "script body must survive an edit")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path))
        let parsed = ScriptMetadataParser.parse(contents: contents, url: url)
        XCTAssertEqual(parsed?.title, "New Name")
        XCTAssertEqual(parsed?.mode, .silent)
    }

    func testDeleteScriptRequiresConfirmationAndRemovesFile() throws {
        try writeScript("doomed.sh", header: "# @raycast.title Doomed Script", body: "echo bye")
        let model = makeModel()
        waitForScripts(in: model, query: "doomed")
        model.select(index: model.results.firstIndex { $0.kind == .scriptCommand }!)
        let url = directory.appendingPathComponent("doomed.sh")

        model.perform(.deleteScript)
        XCTAssertEqual(model.pendingDeletion?.title, "Doomed Script")

        model.handleEscape()
        XCTAssertNil(model.pendingDeletion)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "escape must not delete the file")

        model.perform(.deleteScript)
        model.handleSubmit()
        XCTAssertNil(model.pendingDeletion)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(model.results.contains { $0.kind == .scriptCommand && $0.title == "Doomed Script" })
    }
}
