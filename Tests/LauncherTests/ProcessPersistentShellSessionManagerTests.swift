import Foundation
import XCTest
@testable import Launcher

final class ProcessPersistentShellSessionManagerTests: XCTestCase {
    private var managers: [ProcessPersistentShellSessionManager] = []
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        managers.forEach { $0.terminateAllImmediately() }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        for url in temporaryURLs { try? FileManager.default.removeItem(at: url) }
        managers.removeAll()
        temporaryURLs.removeAll()
        super.tearDown()
    }

    func testPTYHasTTYControllingTerminalAndJobControl() {
        let manager = makeManager()
        let id = ShellSessionID()
        let ready = expectation(description: "ready")
        let finished = expectation(description: "command finished")
        var transcript = ""

        XCTAssertTrue(manager.startSession(id: id, onOutput: { _, text in
            XCTAssertTrue(Thread.isMainThread)
            transcript += text
        }, onEvent: { _, event in
            XCTAssertTrue(Thread.isMainThread)
            switch event {
            case .ready:
                ready.fulfill()
            case .foregroundFinished:
                finished.fulfill()
            default:
                break
            }
        }))
        wait(for: [ready], timeout: 5)
        XCTAssertFalse(transcript.contains("__launcher_run"), transcript)
        XCTAssertTrue(manager.submitCommand(
            "[ -t 0 ] && [ -t 1 ] && "
                + "[ \"$(ps -o tpgid= -p $$ | tr -d ' ')\" != '-1' ] "
                + "&& sleep 0.05 & wait $! && "
                + "[ \"$TERM\" = dumb ] && [ \"$NO_COLOR\" = 1 ] && "
                + "[ \"$CLAUDE_AX_SCREEN_READER\" = 1 ] && echo PTY_JOB_OK",
            to: id
        ))
        wait(for: [finished], timeout: 5)
        XCTAssertTrue(transcript.contains("PTY_JOB_OK"), transcript)
        XCTAssertFalse(transcript.contains("c2xlZX"), transcript)
    }

    func testSequentialCDPersistsAndUpdatesCWD() throws {
        let directory = try makeTemporaryDirectory(named: "cwd with space")
        let manager = makeManager()
        let id = ShellSessionID()
        let ready = expectation(description: "ready")
        let changed = expectation(description: "cd finished")
        let printed = expectation(description: "pwd finished")
        var transcript = ""
        var finishes = 0

        XCTAssertTrue(manager.startSession(id: id, onOutput: { _, text in transcript += text }, onEvent: {
            _, event in
            switch event {
            case .ready:
                ready.fulfill()
            case let .foregroundFinished(result, cwd):
                XCTAssertEqual(result, .success)
                finishes += 1
                if finishes == 1 {
                    XCTAssertEqual(cwd, directory.path)
                    changed.fulfill()
                } else {
                    printed.fulfill()
                }
            default:
                break
            }
        }))
        wait(for: [ready], timeout: 5)
        XCTAssertFalse(manager.submitCommand("printf before\0after", to: id))
        XCTAssertTrue(manager.submitCommand("cd \(quote(directory.path))", to: id))
        wait(for: [changed], timeout: 5)
        XCTAssertTrue(manager.submitCommand("pwd", to: id))
        wait(for: [printed], timeout: 5)
        XCTAssertTrue(transcript.contains(directory.path), transcript)
    }

    func testForegroundReadAcceptsInputLine() {
        let manager = makeManager()
        let id = ShellSessionID()
        let ready = expectation(description: "ready")
        let started = expectation(description: "foreground started")
        let finished = expectation(description: "foreground finished")
        var transcript = ""

        XCTAssertTrue(manager.startSession(id: id, onOutput: { _, text in transcript += text }, onEvent: {
            _, event in
            switch event {
            case .ready: ready.fulfill()
            case .foregroundStarted: started.fulfill()
            case .foregroundFinished: finished.fulfill()
            default: break
            }
        }))
        wait(for: [ready], timeout: 5)
        XCTAssertFalse(manager.sendInputLine("too early", to: id))
        XCTAssertTrue(manager.submitCommand("read answer; echo received:$answer", to: id))
        wait(for: [started], timeout: 5)
        XCTAssertTrue(manager.sendInputLine("hello interactive world", to: id))
        wait(for: [finished], timeout: 5)
        XCTAssertTrue(transcript.contains("received:hello interactive world"), transcript)
    }

    func testCanonicalLineLimitsRejectAtomicallyAndLeaveSessionUsable() {
        let manager = makeManager()
        let id = ShellSessionID()
        let ready = expectation(description: "ready")
        let maximumCommandFinished = expectation(description: "maximum command finished")
        let readStarted = expectation(description: "read started")
        let inputFinished = expectation(description: "input finished")
        var finishes = 0
        var transcript = ""

        XCTAssertTrue(manager.startSession(id: id, onOutput: { _, text in
            transcript += text
        }, onEvent: { _, event in
            switch event {
            case .ready: ready.fulfill()
            case .foregroundStarted:
                if finishes == 1 { readStarted.fulfill() }
            case .foregroundFinished:
                finishes += 1
                (finishes == 1 ? maximumCommandFinished : inputFinished).fulfill()
            default: break
            }
        }))
        wait(for: [ready], timeout: 5)

        let maximumCommand = ": #" + String(
            repeating: "x",
            count: ProcessPersistentShellSessionManager.maximumCommandBytes - 3
        )
        XCTAssertGreaterThan(maximumCommand.utf8.count, 1_024)
        XCTAssertEqual(
            maximumCommand.utf8.count,
            ProcessPersistentShellSessionManager.maximumCommandBytes
        )
        XCTAssertTrue(manager.submitCommand(maximumCommand, to: id))
        wait(for: [maximumCommandFinished], timeout: 10)

        XCTAssertFalse(manager.submitCommand(maximumCommand + "x", to: id))
        XCTAssertFalse(manager.submitCommand("echo before\0after", to: id))
        XCTAssertTrue(manager.submitCommand("read answer; echo input-length:${#answer}", to: id))
        wait(for: [readStarted], timeout: 5)

        let maximumInput = String(
            repeating: "i",
            count: ProcessPersistentShellSessionManager.maximumTerminalLineBytes - 1
        )
        XCTAssertFalse(manager.sendInputLine(maximumInput + "i", to: id))
        XCTAssertFalse(manager.sendInputLine("before\0after", to: id))
        XCTAssertFalse(manager.sendInputLine("two\nrecords", to: id))
        XCTAssertFalse(manager.sendInputLine("two\rrecords", to: id))
        XCTAssertTrue(manager.sendInputLine(maximumInput, to: id))
        wait(for: [inputFinished], timeout: 5)
        XCTAssertTrue(transcript.contains("input-length:\(maximumInput.utf8.count)"), transcript)
    }

    func testStartupTimeoutClosesBlockedZshInitializationAsFailedToStart() throws {
        let startupDirectory = try makeTemporaryDirectory(named: "blocked-zdotdir")
        let zshrc = startupDirectory.appendingPathComponent(".zshrc")
        try "while IFS= read -r ignored; do :; done\n".write(to: zshrc, atomically: true, encoding: .utf8)
        var environment = ProcessInfo.processInfo.environment
        environment["ZDOTDIR"] = startupDirectory.path
        let manager = makeManager(
            environment: environment,
            startupTimeout: 0.1
        )
        let id = ShellSessionID()
        let closed = expectation(description: "timed out shell closed")
        var closedResult: ScriptRunResult?

        XCTAssertTrue(manager.startSession(id: id, onOutput: { _, _ in }, onEvent: { _, event in
            switch event {
            case .ready:
                XCTFail("A shell blocked in .zshrc must not become ready")
            case let .closed(result):
                closedResult = result
                closed.fulfill()
            default:
                break
            }
        }))

        wait(for: [closed], timeout: 3)
        guard case let .failedToStart(message) = closedResult else {
            return XCTFail("Expected failedToStart, got \(String(describing: closedResult))")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("timed out"), message)
        XCTAssertTrue(manager.activeSessionIDs.isEmpty)
    }

    func testInterruptReturnsReadyAndNextCommandWorks() throws {
        let directory = try makeTemporaryDirectory(named: "interrupt-cwd")
        let manager = makeManager()
        let id = ShellSessionID()
        let ready = expectation(description: "ready")
        let started = expectation(description: "sleep started")
        let interrupted = expectation(description: "sleep interrupted")
        let recovered = expectation(description: "later command finished")
        var foregroundFinishes = 0
        var transcript = ""

        XCTAssertTrue(manager.startSession(id: id, onOutput: { _, text in transcript += text }, onEvent: {
            _, event in
            switch event {
            case .ready: ready.fulfill()
            case .foregroundStarted:
                if foregroundFinishes == 0 { started.fulfill() }
            case let .foregroundFinished(result, cwd):
                foregroundFinishes += 1
                if foregroundFinishes == 1 {
                    XCTAssertEqual(result, .cancelled)
                    XCTAssertEqual(cwd, directory.path)
                    interrupted.fulfill()
                } else {
                    recovered.fulfill()
                }
            default: break
            }
        }))
        wait(for: [ready], timeout: 5)
        XCTAssertTrue(manager.submitCommand("cd \(quote(directory.path)); sleep 30", to: id))
        wait(for: [started], timeout: 5)
        manager.interruptForeground(in: id)
        manager.interruptForeground(in: id)
        wait(for: [interrupted], timeout: 5)
        XCTAssertTrue(manager.submitCommand("echo recovered", to: id))
        wait(for: [recovered], timeout: 5)
        XCTAssertTrue(transcript.contains("recovered"), transcript)
    }

    func testCompletionUsesSessionCWDAndPATHWithUTF16Range() throws {
        let directory = try makeTemporaryDirectory(named: "completion")
        let local = directory.appendingPathComponent("some file.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: local.path, contents: Data()))
        let executable = directory.appendingPathComponent("session-tool")
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data("#!/bin/sh\n".utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let malicious = directory.appendingPathComponent("bad;$(owned)&.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: malicious.path, contents: Data()))
        let tools = directory.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let relativeExecutable = tools.appendingPathComponent("relative-tool")
        XCTAssertTrue(FileManager.default.createFile(atPath: relativeExecutable.path, contents: Data("#!/bin/sh\n".utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: relativeExecutable.path)
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = directory.path
        environment["PATH"] = "tools:" + directory.path + ":/usr/bin:/bin"
        let manager = makeManager(environment: environment, workingDirectory: directory)
        let id = ShellSessionID()
        let ready = expectation(description: "ready")
        let fileCompletion = expectation(description: "file completion")
        let pathCompletion = expectation(description: "path completion")
        let maliciousCompletion = expectation(description: "escaped completion")
        let tildeCompletion = expectation(description: "tilde completion")
        let relativePATHCompletion = expectation(description: "relative PATH completion")
        let pipeCompletion = expectation(description: "post-pipe completion")
        let directoryCompletion = expectation(description: "directory chaining completion")

        XCTAssertTrue(manager.startSession(id: id, onOutput: { _, _ in }, onEvent: { _, event in
            if case .ready = event { ready.fulfill() }
        }))
        wait(for: [ready], timeout: 5)

        let fileInput = "echo 😀 some"
        let fileCursor = fileInput.utf16.count
        manager.requestCompletions(
            input: fileInput,
            cursorUTF16: fileCursor,
            in: id,
            requestID: ShellCompletionRequestID()
        ) { _, result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(result.replacementRange, (fileCursor - 4)..<fileCursor)
            XCTAssertTrue(result.candidates.contains("some\\ file.txt"), "\(result.candidates)")
            fileCompletion.fulfill()
        }
        manager.requestCompletions(
            input: "session-",
            cursorUTF16: 8,
            in: id,
            requestID: ShellCompletionRequestID()
        ) { _, result in
            XCTAssertTrue(result.candidates.contains("session-tool"), "\(result.candidates)")
            pathCompletion.fulfill()
        }
        manager.requestCompletions(input: "echo bad", cursorUTF16: 8, in: id, requestID: ShellCompletionRequestID()) {
            _, result in
            XCTAssertTrue(result.candidates.contains("bad\\;\\$\\(owned\\)\\&.txt"), "\(result.candidates)")
            maliciousCompletion.fulfill()
        }
        manager.requestCompletions(input: "cat ~/som", cursorUTF16: 9, in: id, requestID: ShellCompletionRequestID()) {
            _, result in
            XCTAssertTrue(result.candidates.contains("~/some\\ file.txt"), "\(result.candidates)")
            tildeCompletion.fulfill()
        }
        manager.requestCompletions(input: "relative-", cursorUTF16: 9, in: id, requestID: ShellCompletionRequestID()) {
            _, result in
            XCTAssertTrue(result.candidates.contains("relative-tool"), "\(result.candidates)")
            relativePATHCompletion.fulfill()
        }
        let pipeInput = "echo x | session-"
        manager.requestCompletions(input: pipeInput, cursorUTF16: pipeInput.utf16.count, in: id, requestID: ShellCompletionRequestID()) {
            _, result in
            XCTAssertTrue(result.candidates.contains("session-tool"), "\(result.candidates)")
            pipeCompletion.fulfill()
        }
        let directoryInput = "cat tools/"
        manager.requestCompletions(input: directoryInput, cursorUTF16: directoryInput.utf16.count, in: id, requestID: ShellCompletionRequestID()) {
            _, result in
            XCTAssertTrue(result.candidates.contains("tools/relative-tool"), "\(result.candidates)")
            directoryCompletion.fulfill()
        }
        wait(for: [fileCompletion, pathCompletion, maliciousCompletion, tildeCompletion, relativePATHCompletion, pipeCompletion, directoryCompletion], timeout: 5)
    }

    func testCompletionTracksHOMEAndUnderstandsShellCommandContexts() throws {
        let initialHome = try makeTemporaryDirectory(named: "initial-home")
        let changedHome = initialHome.deletingLastPathComponent().appendingPathComponent("changed-home")
        try FileManager.default.createDirectory(at: changedHome, withIntermediateDirectories: true)
        let changedFile = changedHome.appendingPathComponent("changed target.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: changedFile.path, contents: Data()))

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = initialHome.path
        environment["PATH"] = "/usr/bin:/bin"
        let manager = makeManager(environment: environment, workingDirectory: initialHome)
        let id = ShellSessionID()
        let ready = expectation(description: "ready")
        let contextChanged = expectation(description: "completion context changed")

        XCTAssertTrue(manager.startSession(id: id, onOutput: { _, _ in }, onEvent: { _, event in
            switch event {
            case .ready: ready.fulfill()
            case .foregroundFinished: contextChanged.fulfill()
            default: break
            }
        }))
        wait(for: [ready], timeout: 5)
        XCTAssertTrue(manager.submitCommand("export HOME=\(quote(changedHome.path))", to: id))
        wait(for: [contextChanged], timeout: 5)

        let checks: [(String, String, String)] = [
            ("builtin", "seto", "setopt"),
            ("assignment", "FOO=bar pri", "printf"),
            ("attached redirection", "echo ok >~/cha", "~/changed\\ target.txt"),
            ("spaced redirection", "echo ok > ~/cha", "~/changed\\ target.txt"),
            ("descriptor redirection", "echo ok 2>~/cha", "~/changed\\ target.txt"),
            ("append redirection", "echo ok 2>>~/cha", "~/changed\\ target.txt"),
            ("combined redirection", "echo ok &>~/cha", "~/changed\\ target.txt"),
            ("leading redirection", "> /tmp/out pri", "printf"),
            ("operator", "echo ok || pri", "printf"),
            ("attached operator", "echo ok;pri", "printf"),
        ]
        let completions = expectation(description: "all completion contexts")
        completions.expectedFulfillmentCount = checks.count + 1

        for (label, input, expected) in checks {
            let cursor = input.utf16.count
            manager.requestCompletions(
                input: input,
                cursorUTF16: cursor,
                in: id,
                requestID: ShellCompletionRequestID()
            ) { _, result in
                XCTAssertTrue(
                    result.candidates.contains(expected),
                    "\(label): expected \(expected) in \(result.candidates)"
                )
                if let tokenRange = input.range(of: input.hasSuffix("pri") ? "pri" : "~/cha", options: .backwards) {
                    XCTAssertEqual(
                        result.replacementRange.lowerBound,
                        input.utf16.distance(from: input.utf16.startIndex, to: tokenRange.lowerBound.samePosition(in: input.utf16)!)
                    )
                }
                completions.fulfill()
            }
        }

        let midInput = "echo 😀 /usr/bin/pri suffix"
        let midStart = ("echo 😀 " as NSString).length
        let midCursor = ("echo 😀 /usr/bin/pri" as NSString).length
        manager.requestCompletions(
            input: midInput,
            cursorUTF16: midCursor,
            in: id,
            requestID: ShellCompletionRequestID()
        ) { _, result in
            XCTAssertEqual(result.replacementRange, midStart..<midCursor)
            XCTAssertTrue(result.candidates.contains("/usr/bin/printf"), "\(result.candidates)")
            completions.fulfill()
        }
        wait(for: [completions], timeout: 5)
    }

    func testTwoSessionsAreIndependentAndCloseAndTerminate() throws {
        let firstDirectory = try makeTemporaryDirectory(named: "first")
        let secondDirectory = try makeTemporaryDirectory(named: "second")
        let manager = makeManager()
        let first = ShellSessionID()
        let second = ShellSessionID()
        let ready = expectation(description: "both ready")
        ready.expectedFulfillmentCount = 2
        let changed = expectation(description: "both changed")
        changed.expectedFulfillmentCount = 2
        let firstClosed = expectation(description: "first closed")
        let secondClosed = expectation(description: "second closed")
        var cwdByID: [ShellSessionID: String] = [:]

        let events: (ShellSessionID, ShellSessionEvent) -> Void = { id, event in
            switch event {
            case .ready: ready.fulfill()
            case let .foregroundFinished(_, cwd):
                cwdByID[id] = cwd
                changed.fulfill()
            case .closed:
                (id == first ? firstClosed : secondClosed).fulfill()
            default: break
            }
        }
        XCTAssertTrue(manager.startSession(id: first, onOutput: { _, _ in }, onEvent: events))
        XCTAssertTrue(manager.startSession(id: second, onOutput: { _, _ in }, onEvent: events))
        XCTAssertFalse(manager.startSession(id: first, onOutput: { _, _ in }, onEvent: events))
        wait(for: [ready], timeout: 5)
        XCTAssertEqual(manager.activeSessionIDs, [first, second])
        XCTAssertTrue(manager.submitCommand("cd \(quote(firstDirectory.path))", to: first))
        XCTAssertTrue(manager.submitCommand("cd \(quote(secondDirectory.path))", to: second))
        wait(for: [changed], timeout: 5)
        XCTAssertEqual(cwdByID[first], firstDirectory.path)
        XCTAssertEqual(cwdByID[second], secondDirectory.path)

        manager.closeSession(first)
        wait(for: [firstClosed], timeout: 5)
        XCTAssertEqual(manager.activeSessionIDs, [second])
        manager.terminateAllImmediately()
        wait(for: [secondClosed], timeout: 5)
        XCTAssertTrue(manager.activeSessionIDs.isEmpty)
    }

    func testFastFinalOutputIsDeliveredBeforeFinishedAndClosed() {
        let manager = makeManager()
        let id = ShellSessionID()
        let ready = expectation(description: "ready")
        let finished = expectation(description: "finished")
        let closed = expectation(description: "closed")
        var transcript = ""
        var observedAtFinish = ""
        var observedAtClose = ""

        XCTAssertTrue(manager.startSession(id: id, onOutput: { _, text in
            transcript += text
        }, onEvent: { _, event in
            switch event {
            case .ready:
                ready.fulfill()
            case .foregroundFinished:
                observedAtFinish = transcript
                finished.fulfill()
            case .closed:
                observedAtClose = transcript
                closed.fulfill()
            default:
                break
            }
        }))
        wait(for: [ready], timeout: 5)
        XCTAssertTrue(manager.submitCommand("/usr/bin/printf FAST_FINAL_OUTPUT", to: id))
        wait(for: [finished], timeout: 5)
        XCTAssertTrue(observedAtFinish.contains("FAST_FINAL_OUTPUT"), observedAtFinish)
        manager.closeSession(id)
        wait(for: [closed], timeout: 5)
        XCTAssertTrue(observedAtClose.contains("FAST_FINAL_OUTPUT"), observedAtClose)
    }

    func testInterruptDoesNotInjectRecoveryIntoSignalHandlingForegroundProgram() {
        let manager = makeManager()
        let id = ShellSessionID()
        let ready = expectation(description: "ready")
        let readerStarted = expectation(description: "reader started")
        let finished = expectation(description: "reader finished")
        var transcript = ""
        var didObserveReader = false

        XCTAssertTrue(manager.startSession(id: id, onOutput: { _, text in
            transcript += text
            if !didObserveReader, transcript.contains("READER_READY") {
                didObserveReader = true
                readerStarted.fulfill()
            }
        }, onEvent: { _, event in
            switch event {
            case .ready: ready.fulfill()
            case .foregroundFinished: finished.fulfill()
            default: break
            }
        }))
        wait(for: [ready], timeout: 5)
        let perl = #"/usr/bin/perl -e '$SIG{INT}="IGNORE"; $|=1; print "READER_READY\n"; my $line=<STDIN>; print "READER:$line";'"#
        XCTAssertTrue(manager.submitCommand(perl, to: id))
        wait(for: [readerStarted], timeout: 5)
        manager.interruptForeground(in: id)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        XCTAssertTrue(manager.sendInputLine("user supplied", to: id))
        wait(for: [finished], timeout: 5)
        XCTAssertTrue(transcript.contains("READER:user supplied"), transcript)
        XCTAssertFalse(transcript.contains("__launcher_finish 130"), transcript)
    }

    private func makeManager(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        startupTimeout: TimeInterval = 8
    ) -> ProcessPersistentShellSessionManager {
        let manager = ProcessPersistentShellSessionManager(
            shellPath: "/bin/zsh",
            environment: environment,
            workingDirectory: workingDirectory,
            helperExecutablePath: helperExecutablePath(),
            startupTimeout: startupTimeout
        )
        managers.append(manager)
        return manager
    }

    private func helperExecutablePath() -> String {
        let productsCandidate = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("Launcher")
        if FileManager.default.isExecutableFile(atPath: productsCandidate.path) {
            return productsCandidate.path
        }
        let appCandidate = Bundle.main.executableURL?.path ?? ""
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: appCandidate), appCandidate)
        return appCandidate
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("launcher-session-tests-\(UUID().uuidString)")
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(root)
        return url
    }

    private func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
