import Darwin
import XCTest
@testable import Launcher

final class ProcessShellCommandRunnerTests: XCTestCase {
    private var directory: URL!
    private var runner: ProcessScriptRunner!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shell-runner-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        runner = ProcessScriptRunner(environmentProvider: {
            ProcessInfo.processInfo.environment
        })
    }

    override func tearDownWithError() throws {
        runner.cancel()
        try? FileManager.default.removeItem(at: directory)
    }

    private func runToCompletion(
        _ rawCommand: String,
        timeout: TimeInterval = 10
    ) -> (accepted: Bool, output: String, result: ScriptRunResult?) {
        var output = ""
        var result: ScriptRunResult?
        let done = expectation(description: "shell completion")
        let accepted = runner.runShellCommand(
            rawCommand,
            onOutput: { output += $0 },
            onCompletion: {
                result = $0
                done.fulfill()
            }
        )
        if accepted {
            wait(for: [done], timeout: timeout)
        }
        return (accepted, output, result)
    }

    @discardableResult
    private func writeScript(_ name: String, body: String) throws -> ScriptCommand {
        let url = directory.appendingPathComponent(name)
        let contents = "#!/bin/sh\n# @raycast.title \(name)\n\(body)\n"
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        return ScriptCommand(
            id: url.path,
            url: url,
            title: name,
            mode: .normal,
            packageName: nil,
            description: nil,
            needsConfirmation: false,
            arguments: []
        )
    }

    func testRawCommandPreservesQuotesAndPipes() {
        let run = runToCompletion(
            "printf '%s\\n' 'hello quoted world' | tr '[:lower:]' '[:upper:]'"
        )

        XCTAssertTrue(run.accepted)
        XCTAssertEqual(run.result, .success)
        XCTAssertEqual(run.output, "HELLO QUOTED WORLD\n")
    }

    func testShellStartsInHomeDirectory() {
        let run = runToCompletion("pwd -P")

        XCTAssertEqual(run.result, .success)
        XCTAssertEqual(
            run.output.trimmingCharacters(in: .whitespacesAndNewlines),
            FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        )
    }

    func testShellReceivesLoginEnvironmentWithTerminalOverrides() throws {
        runner = ProcessScriptRunner(environmentProvider: {
            [
                "PATH": "/usr/bin:/bin",
                "RUNNER_TEST_VALUE": "from-login-environment",
                "SHELL": "/not/the/user-shell",
                "TERM": "xterm-256color",
                "NO_COLOR": "0",
                "COLORTERM": "truecolor",
            ]
        })
        let shellPath = try XCTUnwrap(ShellEnvironment.loginShellPath())

        let run = runToCompletion(
            "printf '%s\\n' \"$SHELL\" \"$TERM\" \"$NO_COLOR\" "
                + "\"${COLORTERM-unset}\" \"$RUNNER_TEST_VALUE\""
        )

        XCTAssertEqual(run.result, .success)
        XCTAssertEqual(
            run.output.split(separator: "\n").map(String.init),
            [shellPath, "dumb", "1", "unset", "from-login-environment"]
        )
    }

    func testEmbeddedNULFailsVisiblyWithoutSpawning() {
        let marker = directory.appendingPathComponent("must-not-exist")
        let run = runToCompletion("printf before\0; touch '\(marker.path)'")

        XCTAssertTrue(run.accepted)
        XCTAssertEqual(run.output, "")
        guard case let .failedToStart(message) = run.result else {
            return XCTFail("expected failedToStart, got \(String(describing: run.result))")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("NUL"), message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(runner.isRunning)
    }

    func testOversizedCommandFailsVisiblyWithoutSpawning() {
        let run = runToCompletion(
            String(repeating: "x", count: ProcessScriptRunner.maximumShellCommandBytes + 1)
        )

        XCTAssertTrue(run.accepted)
        guard case let .failedToStart(message) = run.result else {
            return XCTFail("expected failedToStart, got \(String(describing: run.result))")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("too long"), message)
        XCTAssertFalse(runner.isRunning)
    }

    func testNonZeroExitReportsFailure() {
        let run = runToCompletion("printf 'failed\\n' >&2; exit 23")

        XCTAssertEqual(run.output, "failed\n")
        XCTAssertEqual(run.result, .failure(exitCode: 23))
    }

    func testLargeOSCControlStringIsRemovedBeforeOutputBounding() {
        let run = runToCompletion(
            "printf '\\033]52;c;'; yes secret | head -c 150000; sleep 0.2; printf '\\aSAFE\\n'"
        )

        XCTAssertEqual(run.result, .success)
        XCTAssertEqual(run.output, "SAFE\n")
    }

    func testShellAndScriptsShareOneBusySlot() throws {
        let script = try writeScript("other.sh", body: "echo should-not-run")
        let shellReady = expectation(description: "shell ready")
        let shellDone = expectation(description: "shell done")
        var sawReady = false

        XCTAssertTrue(runner.runShellCommand(
            "echo shell-ready; sleep 30",
            onOutput: { output in
                if output.contains("shell-ready"), !sawReady {
                    sawReady = true
                    shellReady.fulfill()
                }
            },
            onCompletion: { _ in shellDone.fulfill() }
        ))
        wait(for: [shellReady], timeout: 5)
        XCTAssertFalse(runner.run(
            script,
            arguments: [],
            onOutput: { _ in },
            onCompletion: { _ in }
        ))

        runner.cancel()
        wait(for: [shellDone], timeout: 5)

        let scriptReady = expectation(description: "script ready")
        let scriptDone = expectation(description: "script done")
        XCTAssertTrue(runner.run(
            try writeScript("busy.sh", body: "echo script-ready; sleep 30"),
            arguments: [],
            onOutput: { output in
                if output.contains("script-ready") { scriptReady.fulfill() }
            },
            onCompletion: { _ in scriptDone.fulfill() }
        ))
        wait(for: [scriptReady], timeout: 5)
        XCTAssertFalse(runner.runShellCommand(
            "echo should-not-run",
            onOutput: { _ in },
            onCompletion: { _ in }
        ))

        runner.cancel()
        wait(for: [scriptDone], timeout: 5)
    }

    func testShellCancellationSendsSIGINTBeforeEscalation() throws {
        let signalFile = directory.appendingPathComponent("signal")
        let started = expectation(description: "shell started")
        let done = expectation(description: "shell completion")
        var sawStarted = false
        var result: ScriptRunResult?
        let command = """
        trap 'printf INT > '\''\(signalFile.path)'\''; exit 0' INT
        trap 'printf TERM > '\''\(signalFile.path)'\''; exit 0' TERM
        echo started
        while :; do sleep 1; done
        """

        XCTAssertTrue(runner.runShellCommand(
            command,
            onOutput: { output in
                if output.contains("started"), !sawStarted {
                    sawStarted = true
                    started.fulfill()
                }
            },
            onCompletion: {
                result = $0
                done.fulfill()
            }
        ))
        wait(for: [started], timeout: 5)

        let cancelledAt = Date()
        runner.cancel()
        wait(for: [done], timeout: 5)

        XCTAssertEqual(result, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 1.5)
        XCTAssertEqual(
            try String(contentsOf: signalFile, encoding: .utf8),
            "INT",
            "shell commands must receive SIGINT, not the script runner's SIGTERM"
        )
    }

    func testImmediateTerminationKillsACommandThatIgnoresInterrupts() {
        let started = expectation(description: "shell started")
        let done = expectation(description: "shell completion")
        var sawStarted = false
        var result: ScriptRunResult?

        XCTAssertTrue(runner.runShellCommand(
            "trap '' INT TERM; echo started; while :; do sleep 30; done",
            onOutput: { output in
                if output.contains("started"), !sawStarted {
                    sawStarted = true
                    started.fulfill()
                }
            },
            onCompletion: {
                result = $0
                done.fulfill()
            }
        ))
        wait(for: [started], timeout: 5)

        let terminatedAt = Date()
        runner.terminateImmediately()
        wait(for: [done], timeout: 2)

        XCTAssertEqual(result, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(terminatedAt), 1)
        XCTAssertFalse(runner.isRunning)
    }
}
