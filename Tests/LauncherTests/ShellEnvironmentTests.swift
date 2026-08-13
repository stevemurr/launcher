import Darwin
import XCTest
@testable import Launcher

final class ShellEnvironmentTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shell-env-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes an executable stand-in for a login shell. It ignores the `-ilc`
    /// arguments the real capture passes and prints `body` instead.
    private func writeFakeShell(_ name: String, body: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func dump(_ pairs: [String]) -> String {
        let payload = pairs.map { "printf '%s\\000' '\($0)'" }.joined(separator: "\n")
        return "printf '%s' '__LAUNCHER_ENV_BEGIN__'\n\(payload)\nprintf '%s' '__LAUNCHER_ENV_END__'"
    }

    // MARK: - Parsing

    func testParseExtractsPairsBetweenMarkers() {
        let raw = "startup noise\n__LAUNCHER_ENV_BEGIN__PATH=/opt/homebrew/bin:/usr/bin\0HOME=/Users/x\0__LAUNCHER_ENV_END__"

        let parsed = ShellEnvironment.parse(Data(raw.utf8))

        XCTAssertEqual(parsed?["PATH"], "/opt/homebrew/bin:/usr/bin")
        XCTAssertEqual(parsed?["HOME"], "/Users/x")
        XCTAssertNil(parsed?["startup noise"])
    }

    func testParseKeepsValuesContainingEqualsAndNewlines() {
        let raw = "__LAUNCHER_ENV_BEGIN__OPTS=--flag=1 --other=2\0LS_COLORS=di=1;34:ln=35\0BLOCK=line one\nline two\0__LAUNCHER_ENV_END__"

        let parsed = ShellEnvironment.parse(Data(raw.utf8))

        XCTAssertEqual(parsed?["OPTS"], "--flag=1 --other=2")
        XCTAssertEqual(parsed?["LS_COLORS"], "di=1;34:ln=35")
        XCTAssertEqual(parsed?["BLOCK"], "line one\nline two")
    }

    func testParseSkipsMalformedEntriesAndEmptyValues() {
        let raw = "__LAUNCHER_ENV_BEGIN__GOOD=yes\0no-equals-sign\0=novalue\0EMPTY=\0__LAUNCHER_ENV_END__"

        let parsed = ShellEnvironment.parse(Data(raw.utf8))

        XCTAssertEqual(parsed?["GOOD"], "yes")
        XCTAssertEqual(parsed?["EMPTY"], "")
        XCTAssertEqual(parsed?.count, 2)
    }

    func testParseReturnsNilWithoutBothMarkers() {
        // A shell killed mid-dump must not be mistaken for a complete
        // environment — a truncated PATH is worse than falling back.
        XCTAssertNil(ShellEnvironment.parse(Data("__LAUNCHER_ENV_BEGIN__PATH=/usr/bin\0".utf8)))
        XCTAssertNil(ShellEnvironment.parse(Data("PATH=/usr/bin\0__LAUNCHER_ENV_END__".utf8)))
        XCTAssertNil(ShellEnvironment.parse(Data()))
    }

    // MARK: - Capture

    func testCaptureReadsDumpPastStartupNoise() throws {
        let shell = try writeFakeShell("noisy.sh", body: """
        echo 'Welcome to your shell!'
        echo 'plugin loaded' 1>&2
        \(dump(["PATH=/opt/homebrew/bin:/usr/bin", "MISE_SHELL=zsh"]))
        """)

        let captured = ShellEnvironment.capture(shell: shell, arguments: ["-ilc", "ignored"], timeout: 5)

        XCTAssertEqual(captured?["PATH"], "/opt/homebrew/bin:/usr/bin")
        XCTAssertEqual(captured?["MISE_SHELL"], "zsh")
    }

    func testCaptureGivesUpOnHangingShell() throws {
        let shell = try writeFakeShell("hang.sh", body: "sleep 30")

        let startedAt = Date()
        let captured = ShellEnvironment.capture(shell: shell, arguments: ["-ilc", "ignored"], timeout: 1)

        XCTAssertNil(captured)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 5, "the timeout must bound the wait")
    }

    func testCaptureRejectsUnboundedStartupNoisePromptly() throws {
        let shell = try writeFakeShell("noisy-forever.sh", body: "yes startup-noise")

        let startedAt = Date()
        let captured = ShellEnvironment.capture(
            shell: shell,
            arguments: ["-ilc", "ignored"],
            timeout: 5
        )

        XCTAssertNil(captured)
        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            2,
            "the byte cap must abort before the wall-clock timeout"
        )
    }

    func testCaptureFinishesWhileDescendantHoldsThePipe() throws {
        // A backgrounded descendant inherits the write end, so EOF never
        // arrives; the end marker has to be what ends the read. Capture owns
        // its temporary process group, so the descendant must also be gone
        // before capture returns.
        let pidFile = directory.appendingPathComponent("lingering-child.pid")
        let shell = try writeFakeShell("lingering.sh", body: """
        sleep 20 &
        echo $! > '\(pidFile.path)'
        \(dump(["PATH=/usr/local/bin"]))
        """)

        let startedAt = Date()
        let captured = ShellEnvironment.capture(shell: shell, arguments: ["-ilc", "ignored"], timeout: 10)

        XCTAssertEqual(captured?["PATH"], "/usr/local/bin")
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 5)
        let childPID = try XCTUnwrap(
            pid_t(String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        )
        defer { _ = kill(childPID, SIGKILL) }
        XCTAssertTrue(
            kill(childPID, 0) == -1 && errno == ESRCH,
            "login-shell capture must not leak rc-file descendants"
        )
    }

    func testCaptureReturnsNilForMissingShell() {
        XCTAssertNil(ShellEnvironment.capture(
            shell: directory.appendingPathComponent("nope").path,
            arguments: ["-ilc", "ignored"],
            timeout: 2
        ))
    }

    func testRealLoginShellReportsAPath() throws {
        let shell = try XCTUnwrap(ShellEnvironment.loginShellPath())
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: shell))

        let captured = try XCTUnwrap(
            ShellEnvironment.captureLoginShellEnvironment(),
            "the real login shell should be able to dump its environment"
        )
        XCTAssertNotNil(captured["PATH"])
        XCTAssertNotNil(captured["HOME"])
    }

    // MARK: - Resolution

    func testResolvedOverlaysCapturedValuesOnProcessEnvironment() {
        let environment = ShellEnvironment(capture: { ["PATH": "/opt/homebrew/bin", "EDITOR": "nvim"] })
            .resolved()

        XCTAssertEqual(environment["PATH"], "/opt/homebrew/bin")
        XCTAssertEqual(environment["EDITOR"], "nvim")
        // Essentials launchd hands us survive even when the shell omits them.
        XCTAssertEqual(environment["HOME"], ProcessInfo.processInfo.environment["HOME"])
    }

    func testResolvedFallsBackToProcessEnvironmentWhenCaptureFails() {
        let environment = ShellEnvironment(capture: { nil }).resolved()

        XCTAssertEqual(environment["PATH"], ProcessInfo.processInfo.environment["PATH"])
        XCTAssertEqual(environment["HOME"], ProcessInfo.processInfo.environment["HOME"])
    }

    func testResolvedDropsShellLocalVariables() {
        let environment = ShellEnvironment(capture: {
            ["PATH": "/usr/bin", "PWD": "/Users/x", "OLDPWD": "/tmp", "_": "/usr/bin/env"]
        }).resolved()

        // The runner sets the working directory itself; a stale PWD would lie
        // about it to any script that reads it.
        XCTAssertNil(environment["PWD"])
        XCTAssertNil(environment["OLDPWD"])
        XCTAssertNil(environment["_"])
    }

    func testCaptureRunsOnlyOnce() {
        var captures = 0
        let environment = ShellEnvironment(capture: {
            captures += 1
            return ["MARKER": "\(captures)"]
        })

        XCTAssertEqual(environment.resolved()["MARKER"], "1")
        XCTAssertEqual(environment.resolved()["MARKER"], "1")
        XCTAssertEqual(captures, 1)
    }

    func testAsyncResolutionReturnsBeforeBlockedCaptureAndCoalescesCallers() {
        let captureStarted = expectation(description: "capture started")
        let resolutionsFinished = expectation(description: "resolutions finished")
        resolutionsFinished.expectedFulfillmentCount = 2
        let releaseCapture = DispatchSemaphore(value: 0)
        let counterLock = NSLock()
        var captures = 0
        var resolvedMarkers: [String] = []

        let environment = ShellEnvironment(capture: {
            counterLock.lock()
            captures += 1
            counterLock.unlock()
            captureStarted.fulfill()
            releaseCapture.wait()
            return ["MARKER": "ready"]
        })

        let startedAt = Date()
        for _ in 0..<2 {
            environment.resolve { result in
                counterLock.lock()
                resolvedMarkers.append(result["MARKER"] ?? "")
                counterLock.unlock()
                resolutionsFinished.fulfill()
            }
        }

        XCTAssertLessThan(
            Date().timeIntervalSince(startedAt),
            0.5,
            "starting an environment resolution must not wait for shell startup"
        )
        wait(for: [captureStarted], timeout: 2)
        releaseCapture.signal()
        wait(for: [resolutionsFinished], timeout: 2)

        counterLock.lock()
        let captureCount = captures
        let markers = resolvedMarkers
        counterLock.unlock()
        XCTAssertEqual(captureCount, 1)
        XCTAssertEqual(markers, ["ready", "ready"])
        XCTAssertEqual(environment.resolved()["MARKER"], "ready")
    }

    func testPrewarmResolvesOffTheCallingThread() {
        let captured = expectation(description: "capture ran")
        let environment = ShellEnvironment(capture: {
            captured.fulfill()
            return ["PATH": "/warmed"]
        })

        environment.prewarm()
        wait(for: [captured], timeout: 5)
        XCTAssertEqual(environment.resolved()["PATH"], "/warmed")
    }
}
