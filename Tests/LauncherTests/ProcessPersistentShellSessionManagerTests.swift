import Darwin
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
        let echoReady = expectation(description: "input echo observed")
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
            case let .inputEchoStateChanged(state):
                XCTAssertEqual(state, .enabled)
                echoReady.fulfill()
            case .foregroundFinished:
                finished.fulfill()
            default:
                break
            }
        }))
        wait(for: [ready, echoReady], timeout: 5)
        XCTAssertEqual(manager.inputEchoState(for: id), .enabled)
        XCTAssertFalse(transcript.contains("__launcher_run"), transcript)
        XCTAssertFalse(transcript.contains("__launcher_private_b64"), transcript)
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

    func testUserProtocolNamespaceMutationCannotWedgeNextCommand() {
        let manager = makeManager()
        let id = ShellSessionID()
        let ready = expectation(description: "ready")
        let mutationFinished = expectation(description: "namespace mutation finished")
        let recovered = expectation(description: "next command finished")
        var finishes = 0
        var transcript = ""

        XCTAssertTrue(manager.startSession(id: id, onOutput: { _, text in
            transcript += text
        }, onEvent: { _, event in
            switch event {
            case .ready:
                ready.fulfill()
            case .foregroundFinished:
                finishes += 1
                (finishes == 1 ? mutationFinished : recovered).fulfill()
            default:
                break
            }
        }))
        wait(for: [ready], timeout: 5)

        // The protocol must not depend on user-mutable helper names or on the
        // current alias/enable state of zsh's `builtin` primitive.
        XCTAssertTrue(manager.submitCommand(
            "unfunction __launcher_run; precmd_functions=(); "
                + "alias builtin=false; disable builtin",
            to: id
        ))
        wait(for: [mutationFinished], timeout: 5)
        XCTAssertTrue(manager.submitCommand("echo PROTOCOL_SURVIVED", to: id))
        wait(for: [recovered], timeout: 5)
        XCTAssertTrue(transcript.contains("PROTOCOL_SURVIVED"), transcript)
        XCTAssertFalse(transcript.contains("__launcher_private_b64"), transcript)
    }

    func testSlowPrecmdIsToleratedAndFinishingInputCannotEscapeTheProtocol() {
        let manager = makeManager()
        let id = ShellSessionID()
        let ready = expectation(description: "ready")
        let hookStarted = expectation(description: "slow precmd started")
        let slowCommandFinished = expectation(description: "slow-hook command finished")
        let followupFinished = expectation(description: "follow-up command finished")
        var transcript = ""
        var observedHook = false
        var finishCount = 0
        var unexpectedClosedResult: ScriptRunResult?

        XCTAssertTrue(manager.startSession(id: id, onOutput: { _, output in
            transcript += output
            if !observedHook, transcript.contains("SLOW_PRECMD_STARTED") {
                observedHook = true
                hookStarted.fulfill()
            }
        }, onEvent: { _, event in
            switch event {
            case .ready:
                ready.fulfill()
            case .foregroundFinished:
                finishCount += 1
                (finishCount == 1 ? slowCommandFinished : followupFinished).fulfill()
            case let .closed(result):
                unexpectedClosedResult = result
            default:
                break
            }
        }))
        wait(for: [ready], timeout: 5)

        // The hook removes itself only after spending two seconds between the
        // F frame and the manager's queued Q probe.
        let slowHook = "slow_precmd() { print SLOW_PRECMD_STARTED; /bin/sleep 2; "
            + "precmd_functions=(${precmd_functions:#slow_precmd}); "
            + "unfunction slow_precmd; }; precmd_functions+=(slow_precmd)"
        XCTAssertTrue(manager.submitCommand(slowHook, to: id))
        wait(for: [hookStarted], timeout: 5)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))

        XCTAssertEqual(
            manager.submitInputLine("echo UNMANAGED_INPUT_SENTINEL", to: id),
            .rejected(.sessionFinishing)
        )
        wait(for: [slowCommandFinished], timeout: 6)
        XCTAssertFalse(transcript.contains("UNMANAGED_INPUT_SENTINEL"), transcript)

        XCTAssertTrue(manager.submitCommand("echo SLOW_PRECMD_SURVIVED", to: id))
        wait(for: [followupFinished], timeout: 5)
        XCTAssertTrue(transcript.contains("SLOW_PRECMD_SURVIVED"), transcript)
        XCTAssertFalse(transcript.contains("UNMANAGED_INPUT_SENTINEL"), transcript)
        XCTAssertNil(unexpectedClosedResult)
    }

    func testWedgedPrecmdStillClosesWithAnActionableProbeTimeout() {
        let manager = makeManager(controlProbeTimeout: 0.25)
        let id = ShellSessionID()
        let ready = expectation(description: "ready")
        let closed = expectation(description: "wedged hook closed")
        var closedResult: ScriptRunResult?

        XCTAssertTrue(manager.startSession(id: id, onOutput: { _, _ in }, onEvent: { _, event in
            switch event {
            case .ready:
                ready.fulfill()
            case let .closed(result):
                closedResult = result
                closed.fulfill()
            default:
                break
            }
        }))
        wait(for: [ready], timeout: 5)
        XCTAssertTrue(manager.submitCommand(
            "wedged_precmd() { /bin/sleep 30; }; precmd_functions+=(wedged_precmd)",
            to: id
        ))
        wait(for: [closed], timeout: 4)
        guard case let .failedToStart(message) = closedResult else {
            return XCTFail("expected actionable protocol failure, got \(String(describing: closedResult))")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("probe timed out"), message)
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
        XCTAssertEqual(
            manager.submitInputLine("too early", to: id),
            .rejected(.sessionNotForeground)
        )
        XCTAssertTrue(manager.submitCommand("read answer; echo received:$answer", to: id))
        wait(for: [started], timeout: 5)
        XCTAssertEqual(manager.inputEchoState(for: id), .enabled)
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
            count: ProcessPersistentShellSessionManager.maximumCanonicalInputBytes
        )
        XCTAssertEqual(
            manager.submitInputLine(maximumInput + "i", to: id),
            .rejected(.canonicalLineTooLong(
                maximumBytes: ProcessPersistentShellSessionManager.maximumCanonicalInputBytes
            ))
        )
        XCTAssertEqual(
            manager.submitInputLine("before\0after", to: id),
            .rejected(.containsNUL)
        )
        XCTAssertEqual(
            manager.submitInputLine("two\nrecords", to: id),
            .rejected(.containsLineBreak)
        )
        XCTAssertEqual(
            manager.submitInputLine("two\rrecords", to: id),
            .rejected(.containsLineBreak)
        )
        XCTAssertEqual(manager.submitInputLine(maximumInput, to: id), .accepted)
        wait(for: [inputFinished], timeout: 5)
        XCTAssertTrue(transcript.contains("input-length:\(maximumInput.utf8.count)"), transcript)
    }

    func testNonCanonicalForegroundAcceptsLongInputAndPublishesEchoTransitions() {
        let manager = makeManager()
        let id = ShellSessionID()
        let ready = expectation(description: "ready")
        let initialEcho = expectation(description: "initial echo enabled")
        let rawReaderReady = expectation(description: "raw reader ready")
        let echoDisabled = expectation(description: "echo disabled")
        let echoRestored = expectation(description: "echo restored")
        let finished = expectation(description: "raw reader finished")
        var transcript = ""
        var echoStates: [ShellInputEchoState] = []
        var observedRawReader = false

        XCTAssertTrue(manager.startSession(id: id, onOutput: { _, text in
            transcript += text
            if !observedRawReader, transcript.contains("RAW_READY") {
                observedRawReader = true
                rawReaderReady.fulfill()
            }
        }, onEvent: { _, event in
            switch event {
            case .ready:
                ready.fulfill()
            case let .inputEchoStateChanged(state):
                echoStates.append(state)
                if echoStates.count == 1, state == .enabled {
                    initialEcho.fulfill()
                } else if state == .disabled {
                    echoDisabled.fulfill()
                } else if echoStates.contains(.disabled), state == .enabled {
                    echoRestored.fulfill()
                }
            case .foregroundFinished:
                finished.fulfill()
            default:
                break
            }
        }))
        wait(for: [ready, initialEcho], timeout: 5)
        XCTAssertEqual(manager.inputEchoState(for: id), .enabled)

        let perl = #"/bin/stty -icanon -echo min 1 time 0; /usr/bin/perl -e '$|=1; print "RAW_READY\n"; my $value=""; while (sysread(STDIN, my $character, 1)) { last if $character eq "\r" || $character eq "\n"; $value.=$character } print "RAW_LENGTH:".length($value)."\n";'; /bin/stty icanon echo"#
        XCTAssertTrue(manager.submitCommand(perl, to: id))
        wait(for: [rawReaderReady, echoDisabled], timeout: 5)
        XCTAssertEqual(manager.inputEchoState(for: id), .disabled)

        let overLimit = String(
            repeating: "x",
            count: ProcessPersistentShellSessionManager.maximumNonCanonicalInputBytes + 1
        )
        XCTAssertEqual(
            manager.submitInputLine(overLimit, to: id),
            .rejected(.nonCanonicalLineTooLong(
                maximumBytes: ProcessPersistentShellSessionManager.maximumNonCanonicalInputBytes
            ))
        )

        let longInput = String(repeating: "r", count: 8 * 1_024)
        XCTAssertEqual(manager.submitInputLine(longInput, to: id), .accepted)
        wait(for: [finished, echoRestored], timeout: 8)
        XCTAssertTrue(
            transcript.contains("RAW_LENGTH:\(longInput.utf8.count)"),
            String(transcript.suffix(1_000))
        )
        XCTAssertEqual(manager.inputEchoState(for: id), .enabled)
        XCTAssertEqual(echoStates, [.enabled, .disabled, .enabled])
    }

    func testQueuedRawInputReturnsPromptlyAndDeliversOneCompleteRecord() {
        let manager = makeManager()
        let id = ShellSessionID()
        let ready = expectation(description: "ready")
        let readerReady = expectation(description: "delayed raw reader ready")
        let finished = expectation(description: "queued raw input finished")
        var transcript = ""
        var observedReady = false

        XCTAssertTrue(manager.startSession(id: id, onOutput: { _, output in
            transcript += output
            if !observedReady, transcript.contains("QUEUED_INPUT_READY") {
                observedReady = true
                readerReady.fulfill()
            }
        }, onEvent: { _, event in
            switch event {
            case .ready: ready.fulfill()
            case .foregroundFinished: finished.fulfill()
            default: break
            }
        }))
        wait(for: [ready], timeout: 5)

        let delayedReader = #"/bin/stty -icanon -echo min 1 time 0; print QUEUED_INPUT_READY; /bin/sleep 1; /usr/bin/perl -e '$|=1; my $value=""; while (sysread(STDIN, my $character, 1)) { last if $character eq "\r" || $character eq "\n"; $value.=$character } print "QUEUED_LENGTH:".length($value)."\n";'; /bin/stty icanon echo"#
        XCTAssertTrue(manager.submitCommand(delayedReader, to: id))
        wait(for: [readerReady], timeout: 5)

        let input = String(repeating: "q", count: ProcessPersistentShellSessionManager.maximumNonCanonicalInputBytes)
        let admissionStarted = Date()
        XCTAssertEqual(manager.submitInputLine(input, to: id), .accepted)
        XCTAssertLessThan(
            Date().timeIntervalSince(admissionStarted),
            0.5,
            "admission must enqueue rather than poll a blocked PTY for one second"
        )

        wait(for: [finished], timeout: 10)
        XCTAssertTrue(
            transcript.contains("QUEUED_LENGTH:\(input.utf8.count)"),
            String(transcript.suffix(1_000))
        )
    }

    func testForegroundEchoObservationBacksOffForQuietLongRunningJobs() {
        let observationLock = NSLock()
        var observationCount = 0
        let manager = makeManager(onTerminalEchoObservation: {
            observationLock.lock()
            observationCount += 1
            observationLock.unlock()
        })
        func currentObservationCount() -> Int {
            observationLock.lock()
            defer { observationLock.unlock() }
            return observationCount
        }

        let id = ShellSessionID()
        let ready = expectation(description: "ready")
        let started = expectation(description: "quiet foreground started")
        let interrupted = expectation(description: "quiet foreground interrupted")
        XCTAssertTrue(manager.startSession(id: id, onOutput: { _, _ in }, onEvent: { _, event in
            switch event {
            case .ready: ready.fulfill()
            case .foregroundStarted: started.fulfill()
            case .foregroundFinished: interrupted.fulfill()
            default: break
            }
        }))
        wait(for: [ready], timeout: 5)
        XCTAssertTrue(manager.submitCommand("/bin/sleep 30", to: id))
        wait(for: [started], timeout: 5)

        let baseline = currentObservationCount()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
        let quietObservations = currentObservationCount() - baseline
        XCTAssertGreaterThan(quietObservations, 10)
        XCTAssertLessThan(
            quietObservations,
            50,
            "quiet persisted jobs must not retain permanent 25ms tcgetattr polling"
        )

        manager.interruptForeground(in: id)
        wait(for: [interrupted], timeout: 5)
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

    func testRepeatedInterruptCompletionAlwaysUsesAuthoritativeCWD() throws {
        let firstDirectory = try makeTemporaryDirectory(named: "interrupt-first")
        let secondDirectory = try makeTemporaryDirectory(named: "interrupt-second")
        let manager = makeManager()
        let id = ShellSessionID()
        let ready = expectation(description: "ready")
        var foregroundStarts = 0
        var finishes: [(ScriptRunResult, String)] = []
        var transcript = ""
        var closedResult: ScriptRunResult?

        XCTAssertTrue(manager.startSession(id: id, onOutput: { _, text in
            transcript += text
        }, onEvent: { _, event in
            switch event {
            case .ready:
                ready.fulfill()
            case .foregroundStarted:
                foregroundStarts += 1
            case let .foregroundFinished(result, cwd):
                finishes.append((result, cwd))
            case let .closed(result):
                closedResult = result
            default:
                break
            }
        }))
        wait(for: [ready], timeout: 5)

        let iterations = 16
        for iteration in 0..<iterations {
            let directory = iteration.isMultiple(of: 2) ? firstDirectory : secondDirectory
            XCTAssertTrue(manager.submitCommand(
                "cd \(quote(directory.path)); /bin/sleep 30",
                to: id
            ))
            XCTAssertTrue(waitUntil(timeout: 4) { foregroundStarts > iteration })
            manager.interruptForeground(in: id)
            XCTAssertTrue(waitUntil(timeout: 4) { finishes.count > iteration }, """
            iteration \(iteration), starts \(foregroundStarts), finishes \(finishes), \
            active \(manager.activeSessionIDs.contains(id)), closed \(String(describing: closedResult)), \
            transcript \(transcript.suffix(2_000))
            """)
            guard finishes.count > iteration else { break }
            XCTAssertEqual(finishes[iteration].0, .cancelled)
            XCTAssertEqual(
                finishes[iteration].1,
                directory.path,
                "iteration \(iteration) published cached cwd before its authoritative control frame"
            )
        }
        XCTAssertEqual(finishes.count, iterations)
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

    func testCompletionReplacementRangeCoversTheWholeTokenAfterTheCaret() throws {
        let directory = try makeTemporaryDirectory(named: "whole-token-completion")
        let quotedCandidate = directory.appendingPathComponent("some file.txt")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: quotedCandidate.path,
            contents: Data()
        ))
        let manager = makeManager(workingDirectory: directory)
        let id = ShellSessionID()
        let ready = expectation(description: "ready")
        let completed = expectation(description: "mid-token completion ranges")
        completed.expectedFulfillmentCount = 3

        XCTAssertTrue(manager.startSession(id: id, onOutput: { _, _ in }, onEvent: { _, event in
            if case .ready = event { ready.fulfill() }
        }))
        wait(for: [ready], timeout: 5)

        let midTokenInput = "/usr/bin/printenv --flag"
        let midTokenCursor = ("/usr/bin/pri" as NSString).length
        let midTokenEnd = ("/usr/bin/printenv" as NSString).length
        manager.requestCompletions(
            input: midTokenInput,
            cursorUTF16: midTokenCursor,
            in: id,
            requestID: ShellCompletionRequestID()
        ) { _, result in
            XCTAssertEqual(result.replacementRange, 0..<midTokenEnd)
            XCTAssertTrue(result.candidates.contains("/usr/bin/printf"), "\(result.candidates)")
            completed.fulfill()
        }

        let quotedInput = #"echo "some fiOLD" --flag"#
        let quotedStart = ("echo " as NSString).length
        let quotedCursor = (#"echo "some fi"# as NSString).length
        let quotedEnd = (#"echo "some fiOLD""# as NSString).length
        manager.requestCompletions(
            input: quotedInput,
            cursorUTF16: quotedCursor,
            in: id,
            requestID: ShellCompletionRequestID()
        ) { _, result in
            XCTAssertEqual(result.replacementRange, quotedStart..<quotedEnd)
            XCTAssertTrue(result.candidates.contains(#""some file.txt""#), "\(result.candidates)")
            completed.fulfill()
        }

        let emojiInput = "echo 😀 /usr/bin/printenv🧪 --flag"
        let emojiStart = ("echo 😀 " as NSString).length
        let emojiCursor = ("echo 😀 /usr/bin/pri" as NSString).length
        let emojiEnd = ("echo 😀 /usr/bin/printenv🧪" as NSString).length
        manager.requestCompletions(
            input: emojiInput,
            cursorUTF16: emojiCursor,
            in: id,
            requestID: ShellCompletionRequestID()
        ) { _, result in
            XCTAssertEqual(result.replacementRange, emojiStart..<emojiEnd)
            XCTAssertTrue(result.candidates.contains("/usr/bin/printf"), "\(result.candidates)")
            completed.fulfill()
        }

        wait(for: [completed], timeout: 5)
    }

    func testCompletionTracksLiveAliasesAndFunctionsWithoutEvaluatingThem() {
        let manager = makeManager()
        let id = ShellSessionID()
        let ready = expectation(description: "ready")
        let definitionsFinished = expectation(description: "definitions finished")
        let removalsFinished = expectation(description: "removals finished")
        var finishCount = 0
        var transcript = ""

        XCTAssertTrue(manager.startSession(id: id, onOutput: { _, output in
            transcript += output
        }, onEvent: { _, event in
            switch event {
            case .ready:
                ready.fulfill()
            case .foregroundFinished:
                finishCount += 1
                (finishCount == 1 ? definitionsFinished : removalsFinished).fulfill()
            default:
                break
            }
        }))
        wait(for: [ready], timeout: 5)

        let aliasName = "launcher_test_live_alias"
        let functionName = "launcher_test_live_function"
        XCTAssertTrue(manager.submitCommand(
            "alias \(aliasName)='print ALIAS_BODY_WAS_EVALUATED'; "
                + "\(functionName)() { print FUNCTION_BODY_WAS_EVALUATED; }",
            to: id
        ))
        wait(for: [definitionsFinished], timeout: 5)

        let discovered = expectation(description: "live commands discovered")
        discovered.expectedFulfillmentCount = 2
        for (prefix, expected) in [
            ("launcher_test_live_a", aliasName),
            ("launcher_test_live_f", functionName),
        ] {
            manager.requestCompletions(
                input: prefix,
                cursorUTF16: (prefix as NSString).length,
                in: id,
                requestID: ShellCompletionRequestID()
            ) { _, result in
                XCTAssertTrue(result.candidates.contains(expected), "\(result.candidates)")
                discovered.fulfill()
            }
        }
        wait(for: [discovered], timeout: 5)
        XCTAssertFalse(transcript.contains("ALIAS_BODY_WAS_EVALUATED"), transcript)
        XCTAssertFalse(transcript.contains("FUNCTION_BODY_WAS_EVALUATED"), transcript)

        XCTAssertTrue(manager.submitCommand(
            "unalias \(aliasName); unfunction \(functionName)",
            to: id
        ))
        wait(for: [removalsFinished], timeout: 5)

        let removed = expectation(description: "removed commands disappear")
        removed.expectedFulfillmentCount = 2
        for (prefix, removedName) in [
            ("launcher_test_live_a", aliasName),
            ("launcher_test_live_f", functionName),
        ] {
            manager.requestCompletions(
                input: prefix,
                cursorUTF16: (prefix as NSString).length,
                in: id,
                requestID: ShellCompletionRequestID()
            ) { _, result in
                XCTAssertFalse(result.candidates.contains(removedName), "\(result.candidates)")
                removed.fulfill()
            }
        }
        wait(for: [removed], timeout: 5)
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

    func testCloseSessionTerminatesMoreThan128BackgroundJobControlChildren() {
        exerciseBackgroundChildCleanup(terminateImmediately: false)
    }

    func testTerminateAllImmediatelyTerminatesMoreThan128BackgroundJobControlChildren() {
        exerciseBackgroundChildCleanup(terminateImmediately: true)
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

    private func exerciseBackgroundChildCleanup(terminateImmediately: Bool) {
        let manager = makeManager()
        let id = ShellSessionID()
        let ready = expectation(description: "ready")
        let closed = expectation(description: "closed")
        var transcript = ""

        XCTAssertTrue(manager.startSession(id: id, onOutput: { _, text in
            transcript += text
        }, onEvent: { _, event in
            switch event {
            case .ready:
                ready.fulfill()
            case .closed:
                closed.fulfill()
            default:
                break
            }
        }))
        wait(for: [ready], timeout: 5)

        let childCount = 140
        let command = "for index in {1..\(childCount)}; do "
            + "/bin/sleep 30 & print -r -- CHILD:$!; "
            + "done; print -r -- ALL_CHILDREN_STARTED; wait"
        XCTAssertTrue(manager.submitCommand(command, to: id))
        XCTAssertTrue(waitUntil(timeout: 10) {
            transcript.contains("ALL_CHILDREN_STARTED")
        }, String(transcript.suffix(2_000)))

        defer {
            // A failing assertion must never leave stress-probe processes alive.
            terminateProcesses(childPIDs(in: transcript))
        }
        let pids = childPIDs(in: transcript)
        XCTAssertEqual(pids.count, childCount, String(transcript.suffix(4_000)))

        if terminateImmediately {
            manager.terminateAllImmediately()
        } else {
            manager.closeSession(id)
        }
        wait(for: [closed], timeout: 8)
        XCTAssertTrue(waitUntil(timeout: 5) {
            pids.allSatisfy { !processExists($0) }
        }, "surviving children: \(pids.filter(processExists))")
        XCTAssertFalse(manager.activeSessionIDs.contains(id))
    }

    @discardableResult
    private func waitUntil(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.01,
        _ predicate: () -> Bool
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !predicate(), Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: pollInterval))
        }
        return predicate()
    }

    private func childPIDs(in transcript: String) -> [pid_t] {
        transcript.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("CHILD:") else { return nil }
            return pid_t(line.dropFirst("CHILD:".count))
        }
    }

    private func processExists(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    private func terminateProcesses(_ pids: [pid_t]) {
        for pid in pids where processExists(pid) { _ = kill(pid, SIGKILL) }
        _ = waitUntil(timeout: 2) { pids.allSatisfy { !self.processExists($0) } }
    }

    private func makeManager(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        startupTimeout: TimeInterval = 8,
        controlProbeTimeout: TimeInterval = 8,
        onTerminalEchoObservation: (() -> Void)? = nil
    ) -> ProcessPersistentShellSessionManager {
        let manager = ProcessPersistentShellSessionManager(
            shellPath: "/bin/zsh",
            environment: environment,
            workingDirectory: workingDirectory,
            helperExecutablePath: helperExecutablePath(),
            startupTimeout: startupTimeout,
            controlProbeTimeout: controlProbeTimeout,
            onTerminalEchoObservation: onTerminalEchoObservation
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
