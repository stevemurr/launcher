import XCTest
@testable import Launcher

final class ProcessScriptRunnerTests: XCTestCase {
    private var directory: URL!
    private var runner: ProcessScriptRunner!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("runner-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Inject the test process's own environment so these cases stay
        // hermetic and don't pay for a real login-shell capture. Environment
        // inheritance itself is covered explicitly below.
        runner = ProcessScriptRunner(environmentProvider: { ProcessInfo.processInfo.environment })
    }

    override func tearDownWithError() throws {
        runner.cancel()
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func writeScript(_ name: String, body: String, executable: Bool = true) throws -> ScriptCommand {
        let url = directory.appendingPathComponent(name)
        let contents = "#!/bin/sh\n# @raycast.title \(name)\n\(body)\n"
        try contents.write(to: url, atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return ScriptCommand(
            id: url.path, url: url, title: name, mode: .normal,
            packageName: nil, description: nil, needsConfirmation: false, arguments: []
        )
    }

    private func runToCompletion(
        _ command: ScriptCommand,
        arguments: [String] = [],
        timeout: TimeInterval = 10
    ) -> (output: String, chunks: Int, result: ScriptRunResult?) {
        var output = ""
        var chunks = 0
        var result: ScriptRunResult?
        let done = expectation(description: "completion")
        runner.run(command, arguments: arguments,
            onOutput: { chunk in
                output += chunk
                chunks += 1
            },
            onCompletion: { runResult in
                result = runResult
                done.fulfill()
            })
        wait(for: [done], timeout: timeout)
        return (output, chunks, result)
    }

    func testEchoScriptSucceedsWithOutput() throws {
        let script = try writeScript("echo.sh", body: "echo hello-runner")

        let run = runToCompletion(script)

        XCTAssertEqual(run.result, .success)
        XCTAssertTrue(run.output.contains("hello-runner"))
        XCTAssertFalse(runner.isRunning)
    }

    func testStdoutAndStderrAreMergedInOrder() throws {
        let script = try writeScript("merged.sh", body: "echo one\necho two 1>&2\necho three")

        let run = runToCompletion(script)

        XCTAssertEqual(run.result, .success)
        let indices = ["one", "two", "three"].compactMap { run.output.range(of: $0)?.lowerBound }
        XCTAssertEqual(indices.count, 3)
        XCTAssertEqual(indices, indices.sorted())
    }

    func testSlowScriptStreamsMultipleChunks() throws {
        let script = try writeScript("slow.sh", body: """
        echo first
        sleep 0.3
        echo second
        sleep 0.3
        echo third
        """)

        let run = runToCompletion(script)

        XCTAssertEqual(run.result, .success)
        XCTAssertGreaterThanOrEqual(run.chunks, 2, "output should stream, not arrive as one blob")
        XCTAssertTrue(run.output.contains("first\nsecond\nthird") || run.output.contains("third"))
    }

    func testNonZeroExitReportsFailure() throws {
        let script = try writeScript("fail.sh", body: "exit 3")

        XCTAssertEqual(runToCompletion(script).result, .failure(exitCode: 3))
    }

    func testCancelTerminatesPromptly() throws {
        let script = try writeScript("sleep.sh", body: "echo started\nsleep 30")

        var result: ScriptRunResult?
        var sawOutputBeforeCompletion = false
        var output = ""
        let done = expectation(description: "completion")
        runner.run(script, arguments: [],
            onOutput: { output += $0 },
            onCompletion: {
                result = $0
                sawOutputBeforeCompletion = output.contains("started")
                done.fulfill()
            })

        let startedAt = Date()
        // Give the script a moment to start, then cancel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.runner.cancel() }
        wait(for: [done], timeout: 8)

        XCTAssertEqual(result, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 5)
        XCTAssertTrue(sawOutputBeforeCompletion, "final output must precede completion")
    }

    func testBackgroundedDescendantDoesNotBlockCompletion() throws {
        // The direct child (the shell script) exits almost immediately, but
        // it leaves behind a descendant that inherits the shared
        // stdout/stderr pipe and keeps its write end open for well past the
        // assertion window below. A blocking drain (readToEnd, which waits
        // for EOF on the pipe) would wait for that descendant to exit too,
        // hanging completion — and, transitively, isRunning/cancel() from
        // the main thread, since they synchronize on the same serial queue
        // — far past this timeout. The fix drains only what's already
        // buffered, non-blockingly, so completion should arrive almost
        // immediately regardless of the lingering descendant.
        let script = try writeScript("background.sh", body: "echo done\nsleep 20 &")

        let run = runToCompletion(script, timeout: 4)

        XCTAssertEqual(run.result, .success)
        XCTAssertTrue(run.output.contains("done"))
        XCTAssertFalse(runner.isRunning)
    }

    func testNonExecutableScriptFallsBackToBash() throws {
        let script = try writeScript("plain.sh", body: "echo via-bash", executable: false)

        let run = runToCompletion(script)

        XCTAssertEqual(run.result, .success)
        XCTAssertTrue(run.output.contains("via-bash"))
    }

    func testRunWhileRunningIsRejected() throws {
        let script = try writeScript("busy.sh", body: "sleep 5")
        let other = try writeScript("other.sh", body: "echo nope")

        let done = expectation(description: "completion")
        runner.run(script, arguments: [], onOutput: { _ in }, onCompletion: { _ in done.fulfill() })

        // Poll until the process registers as running before asserting rejection.
        let deadline = Date().addingTimeInterval(3)
        while !runner.isRunning, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(runner.isRunning)
        XCTAssertFalse(runner.run(other, arguments: [], onOutput: { _ in }, onCompletion: { _ in }))

        runner.cancel()
        wait(for: [done], timeout: 8)
    }

    func testConsecutiveRunsReuseRunnerCleanly() throws {
        // Guards against the runner getting stuck "busy" (or a completion
        // handler clobbering the wrong run's state) after a run finishes —
        // a fresh run() right after completion must be accepted and behave
        // normally.
        let first = try writeScript("first.sh", body: "echo one")
        let second = try writeScript("second.sh", body: "echo two")

        let firstRun = runToCompletion(first)
        XCTAssertEqual(firstRun.result, .success)
        XCTAssertTrue(firstRun.output.contains("one"))
        XCTAssertFalse(runner.isRunning)

        let secondRun = runToCompletion(second)
        XCTAssertEqual(secondRun.result, .success)
        XCTAssertTrue(secondRun.output.contains("two"))
        XCTAssertFalse(runner.isRunning)
    }

    func testArgumentsArriveAsPositionalParameters() throws {
        let script = try writeScript("args.sh", body: "echo \"$1|$2\"")

        let run = runToCompletion(script, arguments: ["alpha", "beta gamma"])

        XCTAssertEqual(run.result, .success)
        XCTAssertTrue(run.output.contains("alpha|beta gamma"))
    }

    func testScriptSeesTheProvidedEnvironment() throws {
        // The whole point of resolving the login shell: a script must see the
        // PATH and exports the user has in Terminal, not launchd's bare set.
        runner = ProcessScriptRunner(environmentProvider: {
            ["PATH": "/opt/homebrew/bin:/usr/bin:/bin", "MY_TOOL_HOME": "/Users/x/tools"]
        })
        let script = try writeScript("env.sh", body: "echo \"$PATH|$MY_TOOL_HOME\"")

        let run = runToCompletion(script)

        XCTAssertEqual(run.result, .success)
        XCTAssertTrue(run.output.contains("/opt/homebrew/bin:/usr/bin:/bin|/Users/x/tools"), run.output)
    }

    func testEnvironmentIsResolvedForEveryRun() throws {
        var resolutions = 0
        runner = ProcessScriptRunner(environmentProvider: {
            resolutions += 1
            return ProcessInfo.processInfo.environment.merging(["RUN_INDEX": "\(resolutions)"]) { _, new in new }
        })
        let script = try writeScript("index.sh", body: "echo \"index=$RUN_INDEX\"")

        XCTAssertTrue(runToCompletion(script).output.contains("index=1"))
        XCTAssertTrue(runToCompletion(script).output.contains("index=2"))
    }

    func testMissingInterpreterReportsFailedToStart() throws {
        let url = directory.appendingPathComponent("ghost.sh")
        let command = ScriptCommand(
            id: url.path, url: url, title: "Ghost", mode: .normal,
            packageName: nil, description: nil, needsConfirmation: false, arguments: []
        )
        // File does not exist and is not executable -> bash fallback runs and
        // exits non-zero; an executable-but-missing file fails to start.
        var result: ScriptRunResult?
        let done = expectation(description: "completion")
        runner.run(command, arguments: [], onOutput: { _ in }, onCompletion: { result = $0; done.fulfill() })
        wait(for: [done], timeout: 8)

        switch result {
        case .failure, .failedToStart: break
        default: XCTFail("expected failure for missing script, got \(String(describing: result))")
        }
    }

    func testUTF8DecoderHandlesSplitMultibyteSequences() {
        var decoder = ProcessScriptRunner.UTF8StreamDecoder()
        let emoji = Data("héllo 🚀".utf8)

        var decoded = ""
        // Feed one byte at a time — worst case chunking.
        for byte in emoji {
            decoded += decoder.decode(Data([byte]))
        }
        decoded += decoder.flushRemainder()

        XCTAssertEqual(decoded, "héllo 🚀")
    }
}
