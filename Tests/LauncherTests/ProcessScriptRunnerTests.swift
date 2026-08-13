import Darwin
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
    private func writeScript(
        _ name: String,
        body: String,
        executable: Bool = true,
        mode: ScriptMode = .normal
    ) throws -> ScriptCommand {
        let url = directory.appendingPathComponent(name)
        let contents = "#!/bin/sh\n# @raycast.title \(name)\n\(body)\n"
        try contents.write(to: url, atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return ScriptCommand(
            id: url.path, url: url, title: name, mode: mode,
            packageName: nil, description: nil, needsConfirmation: false, arguments: []
        )
    }

    private func runToCompletion(
        _ command: ScriptCommand,
        arguments: [String] = [],
        timeout: TimeInterval = 10
    ) -> (output: String, chunks: Int, maxChunkBytes: Int, result: ScriptRunResult?) {
        var output = ""
        var chunks = 0
        var maxChunkBytes = 0
        var result: ScriptRunResult?
        let done = expectation(description: "completion")
        runner.run(command, arguments: arguments,
            onOutput: { chunk in
                output += chunk
                chunks += 1
                maxChunkBytes = max(maxChunkBytes, chunk.utf8.count)
            },
            onCompletion: { runResult in
                result = runResult
                done.fulfill()
            })
        wait(for: [done], timeout: timeout)
        return (output, chunks, maxChunkBytes, result)
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
        let started = expectation(description: "script started")
        let done = expectation(description: "completion")
        runner.run(script, arguments: [],
            onOutput: {
                output += $0
                if output.contains("started") { started.fulfill() }
            },
            onCompletion: {
                result = $0
                sawOutputBeforeCompletion = output.contains("started")
                done.fulfill()
            })

        wait(for: [started], timeout: 3)
        let startedAt = Date()
        runner.cancel()
        wait(for: [done], timeout: 8)

        XCTAssertEqual(result, .cancelled)
        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            1.5,
            "a cooperative process must not wait for the two-second descendant escalation"
        )
        XCTAssertTrue(sawOutputBeforeCompletion, "final output must precede completion")
    }

    func testRunReturnsBeforeEnvironmentResolutionFinishes() throws {
        let resolutionStarted = expectation(description: "environment resolution started")
        let releaseResolution = DispatchSemaphore(value: 0)
        runner = ProcessScriptRunner(environmentProvider: {
            resolutionStarted.fulfill()
            releaseResolution.wait()
            return ProcessInfo.processInfo.environment.merging(["ASYNC_ENV": "enriched"]) { _, new in new }
        })
        let script = try writeScript("async-env.sh", body: "echo \"$ASYNC_ENV\"")
        let done = expectation(description: "completion")
        var output = ""
        var result: ScriptRunResult?

        let startedAt = Date()
        XCTAssertTrue(runner.run(
            script,
            arguments: [],
            onOutput: { output += $0 },
            onCompletion: { result = $0; done.fulfill() }
        ))
        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            0.5,
            "run() is called from AppKit's main thread and must not wait for shell startup"
        )
        XCTAssertTrue(runner.isRunning, "environment preparation reserves the runner")

        wait(for: [resolutionStarted], timeout: 2)
        releaseResolution.signal()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(result, .success)
        XCTAssertTrue(output.contains("enriched"), output)
    }

    func testCancelWhileResolvingEnvironmentNeverLaunchesScript() throws {
        let resolutionStarted = expectation(description: "environment resolution started")
        let releaseResolution = DispatchSemaphore(value: 0)
        runner = ProcessScriptRunner(environmentProvider: {
            resolutionStarted.fulfill()
            releaseResolution.wait()
            return ProcessInfo.processInfo.environment
        })
        let marker = directory.appendingPathComponent("must-not-exist")
        let script = try writeScript("cancel-preparation.sh", body: "touch \"\(marker.path)\"")
        let done = expectation(description: "completion")
        var results: [ScriptRunResult] = []

        XCTAssertTrue(runner.run(
            script,
            arguments: [],
            onOutput: { _ in },
            onCompletion: { results.append($0); done.fulfill() }
        ))
        wait(for: [resolutionStarted], timeout: 2)

        runner.cancel()
        wait(for: [done], timeout: 2)
        XCTAssertEqual(results, [.cancelled])
        XCTAssertFalse(runner.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        // Let the late resolver callback arrive and prove its run token cannot
        // resurrect the cancelled process or complete it a second time.
        releaseResolution.signal()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(results, [.cancelled])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testDeinitTerminatesAndReapsActiveProcessGroup() throws {
        let pidFile = directory.appendingPathComponent("abandoned.pid")
        let script = try writeScript("abandoned.sh", body: """
        trap '' TERM HUP
        echo $$ > '\(pidFile.path)'
        echo started
        while :; do sleep 30; done
        """)
        var localRunner: ProcessScriptRunner? = ProcessScriptRunner(
            environmentProvider: { ProcessInfo.processInfo.environment }
        )
        let started = expectation(description: "process started")

        XCTAssertTrue(localRunner?.run(
            script,
            arguments: [],
            onOutput: { chunk in
                if chunk.contains("started") { started.fulfill() }
            },
            onCompletion: { _ in }
        ) == true)
        wait(for: [started], timeout: 3)
        let processPID = try XCTUnwrap(
            pid_t(String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        )
        defer { _ = kill(processPID, SIGKILL) }

        localRunner = nil

        let goneDeadline = Date().addingTimeInterval(3)
        while kill(processPID, 0) == 0, Date() < goneDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(
            kill(processPID, 0) == -1 && errno == ESRCH,
            "dropping an active runner must not leak or zombie its process-group leader"
        )
    }

    func testCancelThenImmediateDeinitSchedulesOneCleanup() throws {
        let pidFile = directory.appendingPathComponent("cancel-deinit.pid")
        let script = try writeScript("cancel-deinit.sh", body: """
        trap '' TERM HUP
        echo $$ > '\(pidFile.path)'
        echo started
        while :; do sleep 30; done
        """)
        var localRunner: ProcessScriptRunner? = ProcessScriptRunner(
            environmentProvider: { ProcessInfo.processInfo.environment }
        )
        let started = expectation(description: "process started")
        XCTAssertTrue(localRunner?.run(
            script,
            arguments: [],
            onOutput: { if $0.contains("started") { started.fulfill() } },
            onCompletion: { _ in }
        ) == true)
        wait(for: [started], timeout: 3)
        let processPID = try XCTUnwrap(
            pid_t(String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        )
        defer { _ = kill(processPID, SIGKILL) }

        localRunner?.cancel()
        localRunner = nil

        let goneDeadline = Date().addingTimeInterval(3)
        while kill(processPID, 0) == 0, Date() < goneDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(
            kill(processPID, 0) == -1 && errno == ESRCH,
            "cancel plus owner release must share one cleanup/reaper"
        )
    }

    func testCancelKillsTermIgnoringDescendantProcessGroup() throws {
        let script = try writeScript("tree.sh", body: """
        /bin/sh -c 'trap "" TERM HUP; while :; do sleep 30; done' &
        echo "child=$!"
        wait
        """)
        let done = expectation(description: "completion")
        var childPID: pid_t = -1
        var result: ScriptRunResult?
        let startedAt = Date()

        runner.run(
            script,
            arguments: [],
            onOutput: { [weak self] chunk in
                guard childPID < 0,
                      let range = chunk.range(of: #"child=(\d+)"#, options: .regularExpression),
                      let value = Int32(chunk[range].dropFirst("child=".count))
                else { return }
                childPID = value
                self?.runner.cancel()
            },
            onCompletion: {
                result = $0
                done.fulfill()
            }
        )

        wait(for: [done], timeout: 7)
        defer {
            if childPID > 0 { _ = kill(childPID, SIGKILL) }
        }
        XCTAssertGreaterThan(childPID, 0)
        XCTAssertEqual(result, .cancelled)
        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            1.5,
            "completion need not wait for delayed cleanup of a TERM-ignoring descendant"
        )

        // The old leader remains unreaped as a PGID identity anchor during its
        // grace period, but that cleanup token is independent of current-run
        // state and must neither block nor signal a newly accepted run.
        let second = try writeScript("after-cancel.sh", body: "echo second-run-safe")
        let secondRun = runToCompletion(second)
        XCTAssertEqual(secondRun.result, .success)
        XCTAssertTrue(secondRun.output.contains("second-run-safe"))

        let goneDeadline = Date().addingTimeInterval(3)
        while childPID > 0, kill(childPID, 0) == 0, Date() < goneDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(
            childPID > 0 && kill(childPID, 0) == -1 && errno == ESRCH,
            "cancelling the script must not leave its TERM-ignoring child alive"
        )
    }

    func testBackgroundedDescendantDoesNotBlockCompletion() throws {
        // The direct child (the shell script) exits almost immediately, but
        // starts a descendant that inherits the shared stdout/stderr pipe. A
        // blocking drain would wait for that descendant's EOF. Normal success
        // deliberately preserves intentional background jobs, so the test owns
        // deterministic cleanup rather than changing product semantics.
        let pidFile = directory.appendingPathComponent("background-child.pid")
        defer {
            if let raw = try? String(contentsOf: pidFile, encoding: .utf8),
               let childPID = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                _ = kill(childPID, SIGKILL)
            }
        }
        let script = try writeScript(
            "background.sh",
            body: "sleep 20 & echo $! > '\(pidFile.path)'\necho done"
        )

        let run = runToCompletion(script, timeout: 4)

        XCTAssertEqual(run.result, .success)
        XCTAssertTrue(run.output.contains("done"))
        XCTAssertFalse(runner.isRunning)
        let childPID = try XCTUnwrap(
            pid_t(String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        )
        XCTAssertEqual(
            kill(childPID, 0),
            0,
            "successful scripts may intentionally leave background jobs running"
        )
    }

    func testFastOutputBurstIsBoundedBeforeMainQueueDelivery() throws {
        let byteCount = 2_000_000
        let script = try writeScript(
            "burst.sh",
            body: "/usr/bin/yes x | /usr/bin/head -c \(byteCount)"
        )

        let run = runToCompletion(script, timeout: 8)

        XCTAssertEqual(run.result, .success)
        XCTAssertFalse(run.output.isEmpty)
        XCTAssertLessThanOrEqual(
            run.maxChunkBytes,
            ProcessScriptRunner.maximumPendingOutputBytes,
            "one coalescing window must not dispatch output the UI would immediately discard"
        )
    }

    func testSilentOutputFloodSkipsOutputDelivery() throws {
        let script = try writeScript(
            "silent-burst.sh",
            body: "/usr/bin/yes x | /usr/bin/head -c 2000000",
            mode: .silent
        )
        let done = expectation(description: "completion")
        var outputCallbacks = 0
        var result: ScriptRunResult?

        XCTAssertTrue(runner.run(
            script,
            arguments: [],
            onOutput: { _ in outputCallbacks += 1 },
            onCompletion: { result = $0; done.fulfill() }
        ))
        wait(for: [done], timeout: 5)

        XCTAssertEqual(result, .success)
        XCTAssertEqual(
            outputCallbacks,
            0,
            "silent mode must drain bytes without decoding or dispatching output"
        )
    }

    func testBackgroundOutputProducerCannotSpinFinalDrain() throws {
        let pidFile = directory.appendingPathComponent("background-writer.pid")
        defer {
            if let raw = try? String(contentsOf: pidFile, encoding: .utf8),
               let childPID = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                _ = kill(childPID, SIGKILL)
            }
        }
        let script = try writeScript("background-writer.sh", body: """
        /usr/bin/yes x &
        echo $! > '\(pidFile.path)'
        sleep 0.2
        exit 0
        """)

        let startedAt = Date()
        let run = runToCompletion(script, timeout: 4)

        XCTAssertEqual(run.result, .success)
        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            2,
            "a continuously readable inherited pipe must not make the final drain loop forever"
        )
        XCTAssertLessThanOrEqual(
            run.maxChunkBytes,
            ProcessScriptRunner.maximumPendingOutputBytes
        )
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
