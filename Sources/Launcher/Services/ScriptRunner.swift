import Darwin
import Foundation

enum ScriptRunResult: Equatable {
    case success
    case failure(exitCode: Int32)
    case cancelled
    case failedToStart(String)
}

protocol ScriptRunning: AnyObject {
    var isRunning: Bool { get }

    /// Starts the script. Returns false (doing nothing) when a run is already
    /// active. `onOutput` and `onCompletion` are always delivered on the main
    /// queue, and the final output chunk arrives before the completion.
    @discardableResult
    func run(
        _ command: ScriptCommand,
        arguments: [String],
        onOutput: @escaping (String) -> Void,
        onCompletion: @escaping (ScriptRunResult) -> Void
    ) -> Bool

    /// SIGTERM immediately, SIGKILL if the process is still alive 2 s later.
    func cancel()

    /// Immediately tears down the owned process group during application
    /// shutdown. Test doubles can rely on the default graceful behavior.
    func terminateImmediately()
}

extension ScriptRunning {
    func terminateImmediately() { cancel() }
}

protocol ShellCommandRunning: AnyObject {
    var isRunning: Bool { get }

    /// Starts `rawCommand` in the user's shell. Returns false (doing nothing)
    /// when either a script or another shell command already owns the shared
    /// foreground-process slot. Output and completion follow the same main-
    /// queue ordering guarantee as `ScriptRunning.run`.
    @discardableResult
    func runShellCommand(
        _ rawCommand: String,
        onOutput: @escaping (String) -> Void,
        onCompletion: @escaping (ScriptRunResult) -> Void
    ) -> Bool

    /// SIGINT immediately, SIGKILL if the shell process group is still alive
    /// two seconds later.
    func cancel()

    /// Immediately tears down the owned process group during application
    /// shutdown. Test doubles can rely on the default graceful behavior.
    func terminateImmediately()
}

extension ShellCommandRunning {
    func terminateImmediately() { cancel() }
}

final class ProcessScriptRunner: ScriptRunning, ShellCommandRunning {
    /// Decodes a byte stream as UTF-8, holding back a trailing partial
    /// multi-byte sequence until the next chunk completes it.
    struct UTF8StreamDecoder {
        private var carry = Data()

        mutating func decode(_ data: Data) -> String {
            var buffer = carry + data
            carry.removeAll()

            // Look back over at most 4 bytes for a lead byte whose sequence
            // extends past the buffer end; hold those bytes for the next chunk.
            var holdback = 0
            var continuations = 0
            for offset in 1...4 where offset <= buffer.count {
                let byte = buffer[buffer.index(buffer.endIndex, offsetBy: -offset)]
                if byte & 0b1100_0000 == 0b1000_0000 {
                    continuations += 1
                    if continuations >= 4 { break } // malformed run; decode as-is
                    continue
                }
                let expected: Int
                switch byte {
                case 0b1100_0000...0b1101_1111: expected = 2
                case 0b1110_0000...0b1110_1111: expected = 3
                case 0b1111_0000...0b1111_0111: expected = 4
                default: expected = 0 // ASCII or invalid lead byte
                }
                if expected > offset { holdback = offset }
                break
            }
            if holdback > 0 {
                carry = buffer.suffix(holdback)
                buffer.removeLast(holdback)
            }
            return String(decoding: buffer, as: UTF8.self)
        }

        mutating func flushRemainder() -> String {
            guard !carry.isEmpty else { return "" }
            defer { carry.removeAll() }
            return String(decoding: carry, as: UTF8.self)
        }
    }

    private typealias EnvironmentResolver = (@escaping ([String: String]) -> Void) -> Void

    private final class SpawnedProcess {
        let identifier: pid_t
        let outputFD: Int32
        let initialCancellationSignal: Int32

        /// Left after `waitid(..., WNOWAIT)` has captured the leader's
        /// status without reaping it. Delayed cancellation cleanup waits for
        /// this before reaping, so the zombie anchors the PID/PGID identity
        /// until the group-wide escalation has been sent.
        let exitObserved = DispatchGroup()
        private let cleanupLock = NSLock()
        private var cancellationCleanupScheduled = false

        init(identifier: pid_t, outputFD: Int32, initialCancellationSignal: Int32) {
            self.identifier = identifier
            self.outputFD = outputFD
            self.initialCancellationSignal = initialCancellationSignal
            exitObserved.enter()
        }

        func beginCancellationCleanup() -> Bool {
            cleanupLock.lock()
            defer { cleanupLock.unlock() }
            guard !cancellationCleanupScheduled else { return false }
            cancellationCleanupScheduled = true
            return true
        }
    }

    private enum SpawnResult {
        case success(SpawnedProcess)
        case failure(Int32)
    }

    private enum OutputPolicy {
        case capture
        case discard
    }

    private enum EnvironmentOverride {
        case set(String)
        case remove
    }

    /// Everything that varies between a script and a one-shot shell command.
    /// The surrounding reservation, environment resolution, streaming, wait,
    /// completion, and process-group cleanup paths deliberately stay shared.
    private struct SpawnRequest {
        let executable: String
        /// Complete argv, including argv[0].
        let arguments: [String]
        let workingDirectory: URL
        let outputPolicy: OutputPolicy
        let sanitizesTerminalOutput: Bool
        let environmentOverrides: [String: EnvironmentOverride]
        let initialCancellationSignal: Int32

        func environment(applyingTo base: [String: String]) -> [String: String] {
            var result = base
            for (key, override) in environmentOverrides {
                switch override {
                case let .set(value): result[key] = value
                case .remove: result.removeValue(forKey: key)
                }
            }
            return result
        }
    }

    private let stateQueue = DispatchQueue(label: "launcher.scriptRunner.state")
    private let stateQueueKey = DispatchSpecificKey<UInt8>()
    private let waitQueue = DispatchQueue(
        label: "launcher.scriptRunner.wait",
        qos: .utility,
        attributes: .concurrent
    )
    private var runIdentifier: UInt64 = 0
    /// True from the moment a run is accepted (including asynchronous
    /// environment preparation) until its exit has been fully processed.
    private var isActive = false
    private var cancelRequested = false
    private var spawnedProcess: SpawnedProcess?
    private var outputFD: Int32 = -1
    private var outputSource: DispatchSourceRead?
    private var decoder = UTF8StreamDecoder()
    private var outputSanitizer: TerminalOutputSanitizer?
    private var pendingOutput = ""
    private var flushScheduled = false
    private var onOutput: ((String) -> Void)?
    private var onCompletion: ((ScriptRunResult) -> Void)?

    private static let flushInterval: DispatchTimeInterval = .milliseconds(80)
    private static let killGracePeriod: DispatchTimeInterval = .seconds(2)
    static let maximumShellCommandBytes = 64 * 1_024
    /// Matches the model's retained-output cap. Keeping this bound upstream
    /// prevents a fast producer from assembling and dispatching a multi-megabyte
    /// String during one 80 ms coalescing window, only for the UI to discard it.
    static let maximumPendingOutputBytes = 100_000

    /// Supplies the environment asynchronously. A cold login shell can take
    /// seconds (or time out), so accepting a run must never perform this work on
    /// the caller, which is normally AppKit's main thread.
    private let environmentResolver: EnvironmentResolver

    init() {
        environmentResolver = { ShellEnvironment.shared.resolve($0) }
        stateQueue.setSpecific(key: stateQueueKey, value: 1)
    }

    /// Synchronous injection convenience used by tests and other callers. The
    /// provider itself is always moved off the calling thread.
    init(environmentProvider: @escaping () -> [String: String]) {
        let queue = DispatchQueue(label: "launcher.scriptRunner.environment", qos: .utility)
        environmentResolver = { completion in
            queue.async { completion(environmentProvider()) }
        }
        stateQueue.setSpecific(key: stateQueueKey, value: 1)
    }

    deinit {
        var abandonedProcess: SpawnedProcess?
        var abandonedSource: DispatchSourceRead?
        var abandonedFD: Int32 = -1
        let detachState = {
            abandonedProcess = self.spawnedProcess
            abandonedSource = self.outputSource
            abandonedFD = self.outputFD
            self.outputSource = nil
            self.outputFD = -1
            self.spawnedProcess = nil
            self.outputSanitizer = nil
            self.onOutput = nil
            self.onCompletion = nil
            self.isActive = false
        }
        if DispatchQueue.getSpecific(key: stateQueueKey) != nil {
            detachState()
        } else {
            stateQueue.sync(execute: detachState)
        }

        if let abandonedSource {
            abandonedSource.cancel()
        } else if abandonedFD >= 0 {
            _ = Darwin.close(abandonedFD)
        }

        guard let abandonedProcess else { return }
        scheduleCancellationCleanup(abandonedProcess)
    }

    var isRunning: Bool {
        stateQueue.sync { isActive }
    }

    @discardableResult
    func run(
        _ command: ScriptCommand,
        arguments: [String],
        onOutput: @escaping (String) -> Void,
        onCompletion: @escaping (ScriptRunResult) -> Void
    ) -> Bool {
        let isExecutable = FileManager.default.isExecutableFile(atPath: command.url.path)
        let executable = isExecutable ? command.url.path : "/bin/bash"
        let childArguments = isExecutable ? arguments : [command.url.path] + arguments
        let request = SpawnRequest(
            executable: executable,
            arguments: [executable] + childArguments,
            workingDirectory: command.url.deletingLastPathComponent(),
            outputPolicy: command.mode == .silent ? .discard : .capture,
            sanitizesTerminalOutput: false,
            environmentOverrides: [:],
            initialCancellationSignal: SIGTERM
        )
        return run(
            request,
            onOutput: onOutput,
            onCompletion: onCompletion
        )
    }

    @discardableResult
    func runShellCommand(
        _ rawCommand: String,
        onOutput: @escaping (String) -> Void,
        onCompletion: @escaping (ScriptRunResult) -> Void
    ) -> Bool {
        // C strings cannot represent an embedded NUL. Reject it explicitly so
        // the command is never silently truncated before reaching `-c`.
        guard !rawCommand.contains("\0") else {
            return finishRejectedRequest(
                message: "Shell command contains an embedded NUL byte.",
                onOutput: onOutput,
                onCompletion: onCompletion
            )
        }
        guard rawCommand.utf8.count <= Self.maximumShellCommandBytes else {
            return finishRejectedRequest(
                message: "Shell command is too long (maximum 64 KiB).",
                onOutput: onOutput,
                onCompletion: onCompletion
            )
        }
        guard let shellPath = ShellEnvironment.loginShellPath() else {
            return finishRejectedRequest(
                message: "No usable login shell was found.",
                onOutput: onOutput,
                onCompletion: onCompletion
            )
        }

        let request = SpawnRequest(
            executable: shellPath,
            arguments: [shellPath, "-c", rawCommand],
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
            outputPolicy: .capture,
            sanitizesTerminalOutput: true,
            environmentOverrides: [
                "SHELL": .set(shellPath),
                "TERM": .set("dumb"),
                "NO_COLOR": .set("1"),
                "COLORTERM": .remove,
            ],
            initialCancellationSignal: SIGINT
        )
        return run(
            request,
            onOutput: onOutput,
            onCompletion: onCompletion
        )
    }

    @discardableResult
    private func run(
        _ request: SpawnRequest,
        onOutput: @escaping (String) -> Void,
        onCompletion: @escaping (ScriptRunResult) -> Void
    ) -> Bool {
        let identifier: UInt64? = stateQueue.sync {
            reserveRun(
                outputPolicy: request.outputPolicy,
                sanitizesTerminalOutput: request.sanitizesTerminalOutput,
                onOutput: onOutput,
                onCompletion: onCompletion
            )
        }
        guard let identifier else { return false }

        environmentResolver { [weak self] environment in
            guard let self else { return }
            stateQueue.async {
                self.startProcess(
                    request,
                    environment: request.environment(applyingTo: environment),
                    identifier: identifier
                )
            }
        }
        return true
    }

    /// Accepts a syntactically invalid shell request only when the shared slot
    /// is free, then reports the failure using the normal asynchronous callback
    /// contract without resolving an environment or spawning a child.
    private func finishRejectedRequest(
        message: String,
        onOutput: @escaping (String) -> Void,
        onCompletion: @escaping (ScriptRunResult) -> Void
    ) -> Bool {
        stateQueue.sync {
            guard let identifier = reserveRun(
                outputPolicy: .capture,
                sanitizesTerminalOutput: true,
                onOutput: onOutput,
                onCompletion: onCompletion
            ) else { return false }
            finish(.failedToStart(message), identifier: identifier)
            return true
        }
    }

    /// Reserves the one runner-wide foreground-process slot. Must run on
    /// `stateQueue`.
    private func reserveRun(
        outputPolicy: OutputPolicy,
        sanitizesTerminalOutput: Bool,
        onOutput: @escaping (String) -> Void,
        onCompletion: @escaping (ScriptRunResult) -> Void
    ) -> UInt64? {
        guard !isActive else { return nil }
        runIdentifier &+= 1
        isActive = true
        cancelRequested = false
        spawnedProcess = nil
        outputFD = -1
        outputSource = nil
        decoder = UTF8StreamDecoder()
        outputSanitizer = sanitizesTerminalOutput ? TerminalOutputSanitizer() : nil
        pendingOutput = ""
        flushScheduled = false
        self.onOutput = outputPolicy == .capture ? onOutput : nil
        self.onCompletion = onCompletion
        return runIdentifier
    }

    func cancel() {
        stateQueue.sync {
            guard isActive, !cancelRequested else { return }
            cancelRequested = true
            let identifier = runIdentifier

            // Cancellation during environment preparation completes immediately;
            // the resolver's eventual callback is rejected by its run token.
            guard let spawnedProcess else {
                finish(.cancelled, identifier: identifier)
                return
            }

            // Keep cleanup independent of mutable "current run" state. A
            // cooperative leader can complete promptly and a new run can start
            // during the grace period, while the old unreaped leader prevents
            // its PID/PGID from being reused before this escalation fires.
            scheduleCancellationCleanup(spawnedProcess)
        }
    }

    /// Application termination cannot rely on the normal two-second escalation
    /// timer firing after the app's queues have stopped. Deliver SIGKILL to the
    /// complete owned group synchronously, then leave reaping to the existing
    /// waiter while the process exits.
    func terminateImmediately() {
        stateQueue.sync {
            guard isActive, let spawnedProcess else {
                if isActive {
                    cancelRequested = true
                    finish(.cancelled, identifier: runIdentifier)
                }
                return
            }
            cancelRequested = true
            Self.signalOwnedProcess(spawnedProcess.identifier, signal: SIGKILL)
            if spawnedProcess.beginCancellationCleanup() {
                waitQueue.async {
                    spawnedProcess.exitObserved.wait()
                    Self.reap(spawnedProcess.identifier)
                }
            }
        }
    }

    private func scheduleCancellationCleanup(_ process: SpawnedProcess) {
        guard process.beginCancellationCleanup() else { return }
        Self.signalOwnedProcess(
            process.identifier,
            signal: process.initialCancellationSignal
        )
        waitQueue.asyncAfter(deadline: .now() + Self.killGracePeriod) {
            Self.signalOwnedProcess(process.identifier, signal: SIGKILL)
            process.exitObserved.wait()
            Self.reap(process.identifier)
        }
    }

    // MARK: - Process lifecycle (on stateQueue)

    private func startProcess(
        _ request: SpawnRequest,
        environment: [String: String],
        identifier: UInt64
    ) {
        guard isActive, runIdentifier == identifier, !cancelRequested else { return }

        switch Self.spawn(request, environment: environment) {
        case let .failure(errorCode):
            finish(
                .failedToStart(String(cString: strerror(errorCode))),
                identifier: identifier
            )
        case let .success(spawned):
            spawnedProcess = spawned
            outputFD = spawned.outputFD

            if spawned.outputFD >= 0 {
                let source = DispatchSource.makeReadSource(
                    fileDescriptor: spawned.outputFD,
                    queue: stateQueue
                )
                source.setEventHandler { [weak self] in
                    self?.readAvailableOutput(identifier: identifier)
                }
                source.setCancelHandler {
                    _ = Darwin.close(spawned.outputFD)
                }
                outputSource = source
                source.resume()
            }

            waitQueue.async { [weak self] in
                var info = siginfo_t()
                var waited: Int32
                repeat {
                    waited = waitid(P_PID, id_t(spawned.identifier), &info, WEXITED | WNOWAIT)
                } while waited == -1 && errno == EINTR

                // Whether waitid succeeded or failed, unblock the sole reaper;
                // a failure must not strand the child indefinitely.
                spawned.exitObserved.leave()
                let status = waited == 0 ? Self.waitStatus(from: info) : (127 << 8)

                self?.stateQueue.async {
                    guard let self,
                          self.isActive,
                          self.runIdentifier == identifier,
                          self.spawnedProcess === spawned
                    else { return }
                    self.handleTermination(
                        waitStatus: status,
                        spawnedProcess: spawned,
                        identifier: identifier
                    )
                }
            }
        }
    }

    private func handleTermination(
        waitStatus: Int32,
        spawnedProcess: SpawnedProcess,
        identifier: UInt64
    ) {
        drainAndCloseOutput()

        if !cancelRequested {
            // Successful scripts may intentionally launch background jobs. Reap
            // only their leader; group cleanup is exclusive to explicit cancel.
            waitQueue.async {
                spawnedProcess.exitObserved.wait()
                Self.reap(spawnedProcess.identifier)
            }
        }

        completeAfterTermination(waitStatus: waitStatus, identifier: identifier)
    }

    private func completeAfterTermination(waitStatus: Int32, identifier: UInt64) {
        let result: ScriptRunResult
        if cancelRequested {
            result = .cancelled
        } else if Self.exitedNormally(waitStatus), Self.exitCode(waitStatus) == 0 {
            result = .success
        } else {
            result = .failure(exitCode: Self.terminationCode(waitStatus))
        }
        finish(result, identifier: identifier)
    }

    private func finish(_ result: ScriptRunResult, identifier: UInt64) {
        guard isActive, runIdentifier == identifier else { return }

        if outputFD >= 0 { drainAndCloseOutput() }
        let remainder = decoder.flushRemainder()
        if var sanitizer = outputSanitizer {
            appendPending(sanitizer.sanitize(remainder))
            appendPending(sanitizer.finish())
            outputSanitizer = nil
        } else {
            appendPending(remainder)
        }
        let finalChunk = pendingOutput
        pendingOutput = ""
        flushScheduled = true // suppress any queued timer flush for this run

        let deliverOutput = onOutput
        let deliverCompletion = onCompletion
        onOutput = nil
        onCompletion = nil
        spawnedProcess = nil
        isActive = false

        DispatchQueue.main.async {
            if !finalChunk.isEmpty { deliverOutput?(finalChunk) }
            deliverCompletion?(result)
        }
    }

    private func readAvailableOutput(identifier: UInt64) {
        guard isActive, runIdentifier == identifier, outputFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = read(outputFD, &buffer, buffer.count)
        if count > 0 {
            if onOutput != nil {
                enqueue(data: Data(buffer[0..<count]), identifier: identifier)
            }
        } else if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
            closeOutput()
        }
    }

    private func drainAndCloseOutput() {
        guard outputFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var remainingDrainBytes = Self.maximumPendingOutputBytes
        while remainingDrainBytes > 0 {
            var descriptor = pollfd(fd: outputFD, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 0) > 0 else { break }
            let count = read(outputFD, &buffer, min(buffer.count, remainingDrainBytes))
            if count > 0 {
                if onOutput != nil {
                    appendDecoded(Data(buffer[0..<count]))
                }
                remainingDrainBytes -= count
            } else {
                break
            }
        }
        closeOutput()
    }

    private func closeOutput() {
        let source = outputSource
        outputSource = nil
        let descriptor = outputFD
        outputFD = -1

        if let source {
            // libdispatch requires descriptor closure from the cancellation
            // handler, after it has released the handle and any in-flight event
            // handler has returned. Closing here would permit FD-number reuse
            // while the source still refers to the old integer.
            source.cancel()
        } else if descriptor >= 0 {
            _ = Darwin.close(descriptor)
        }
    }

    // MARK: - Output coalescing (on stateQueue)

    private func enqueue(data: Data, identifier: UInt64) {
        appendDecoded(data)
        guard !flushScheduled else { return }
        flushScheduled = true
        stateQueue.asyncAfter(deadline: .now() + Self.flushInterval) { [weak self] in
            self?.flush(identifier: identifier)
        }
    }

    private func flush(identifier: UInt64) {
        guard isActive, runIdentifier == identifier else { return }
        flushScheduled = false
        guard !pendingOutput.isEmpty, let onOutput else { return }
        let chunk = pendingOutput
        pendingOutput = ""
        DispatchQueue.main.async { onOutput(chunk) }
    }

    private func appendDecoded(_ data: Data) {
        let decoded = decoder.decode(data)
        if var sanitizer = outputSanitizer {
            appendPending(sanitizer.sanitize(decoded))
            outputSanitizer = sanitizer
        } else {
            appendPending(decoded)
        }
    }

    private func appendPending(_ decoded: String) {
        pendingOutput += decoded
        let utf8 = pendingOutput.utf8
        guard utf8.count > Self.maximumPendingOutputBytes else { return }

        var start = utf8.index(
            utf8.endIndex,
            offsetBy: -Self.maximumPendingOutputBytes
        )
        // The source String is valid UTF-8. If the boundary lands inside a
        // scalar, discard its continuation bytes so the delivered chunk stays
        // valid and no larger than the advertised byte limit.
        while start < utf8.endIndex, utf8[start] & 0b1100_0000 == 0b1000_0000 {
            start = utf8.index(after: start)
        }
        pendingOutput = String(decoding: utf8[start...], as: UTF8.self)
    }

    // MARK: - POSIX spawn

    /// `Process` has no pre-exec hook, so setting a process group after
    /// `Process.run()` races the child's `exec`. `posix_spawn` applies the group
    /// attribute atomically while creating the child, which lets cancellation
    /// signal the script and every descendant that remains in its group.
    private static func spawn(
        _ request: SpawnRequest,
        environment: [String: String]
    ) -> SpawnResult {
        let environmentEntries = environment.map { "\($0.key)=\($0.value)" }.sorted()

        var readFD: Int32 = -1
        var writeFD: Int32 = -1
        if request.outputPolicy == .capture {
            var descriptors = [Int32](repeating: -1, count: 2)
            let pipeResult = descriptors.withUnsafeMutableBufferPointer { pipe($0.baseAddress!) }
            guard pipeResult == 0 else { return .failure(errno) }
            readFD = descriptors[0]
            writeFD = descriptors[1]

            let readFlags = fcntl(readFD, F_GETFL)
            if readFlags != -1 { _ = fcntl(readFD, F_SETFL, readFlags | O_NONBLOCK) }
            _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)
            _ = fcntl(writeFD, F_SETFD, FD_CLOEXEC)
        }

        func closeDescriptors() {
            if readFD >= 0 { _ = Darwin.close(readFD) }
            if writeFD >= 0 { _ = Darwin.close(writeFD) }
        }

        var fileActions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        var setupError = posix_spawn_file_actions_init(&fileActions)
        guard setupError == 0 else {
            closeDescriptors()
            return .failure(setupError)
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        setupError = posix_spawnattr_init(&attributes)
        guard setupError == 0 else {
            closeDescriptors()
            return .failure(setupError)
        }
        defer { posix_spawnattr_destroy(&attributes) }

        switch request.outputPolicy {
        case .capture:
            setupError = posix_spawn_file_actions_adddup2(&fileActions, writeFD, STDOUT_FILENO)
            if setupError == 0 {
                setupError = posix_spawn_file_actions_adddup2(&fileActions, writeFD, STDERR_FILENO)
            }
        case .discard:
            setupError = posix_spawn_file_actions_addopen(
                &fileActions,
                STDOUT_FILENO,
                "/dev/null",
                O_WRONLY,
                0
            )
            if setupError == 0 {
                setupError = posix_spawn_file_actions_adddup2(
                    &fileActions,
                    STDOUT_FILENO,
                    STDERR_FILENO
                )
            }
        }
        if setupError == 0 {
            setupError = posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        }
        if setupError == 0, readFD >= 0 {
            setupError = posix_spawn_file_actions_addclose(&fileActions, readFD)
        }
        if setupError == 0, writeFD >= 0 {
            setupError = posix_spawn_file_actions_addclose(&fileActions, writeFD)
        }
        if setupError == 0 {
            setupError = request.workingDirectory.path.withCString {
                posix_spawn_file_actions_addchdir_np(&fileActions, $0)
            }
        }
        if setupError == 0 {
            var defaultSignals = sigset_t()
            sigemptyset(&defaultSignals)
            for signal in [SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGPIPE] {
                sigaddset(&defaultSignals, signal)
            }
            setupError = posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        }
        if setupError == 0 {
            var signalMask = sigset_t()
            sigemptyset(&signalMask)
            setupError = posix_spawnattr_setsigmask(&attributes, &signalMask)
        }
        if setupError == 0 {
            let flags = Int16(
                POSIX_SPAWN_SETPGROUP
                    | POSIX_SPAWN_CLOEXEC_DEFAULT
                    | POSIX_SPAWN_SETSIGDEF
                    | POSIX_SPAWN_SETSIGMASK
            )
            setupError = posix_spawnattr_setflags(&attributes, flags)
        }
        if setupError == 0 {
            // A pgroup value of zero assigns the child's PID as its group ID.
            setupError = posix_spawnattr_setpgroup(&attributes, 0)
        }
        guard setupError == 0 else {
            closeDescriptors()
            return .failure(setupError)
        }

        var childPID: pid_t = 0
        let spawnError = request.executable.withCString { executablePointer in
            withMutableCStringArray(request.arguments) { argumentPointers in
                withMutableCStringArray(environmentEntries) { environmentPointers in
                    posix_spawn(
                        &childPID,
                        executablePointer,
                        &fileActions,
                        &attributes,
                        argumentPointers,
                        environmentPointers
                    )
                }
            }
        }
        guard spawnError == 0 else {
            closeDescriptors()
            return .failure(spawnError)
        }

        if writeFD >= 0 { _ = Darwin.close(writeFD) }
        return .success(SpawnedProcess(
            identifier: childPID,
            outputFD: readFD,
            initialCancellationSignal: request.initialCancellationSignal
        ))
    }

    private static func withMutableCStringArray<Result>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Result
    ) -> Result {
        let storage: [UnsafeMutablePointer<CChar>] = strings.map { strdup($0)! }
        defer { storage.forEach { free($0) } }
        var pointers: [UnsafeMutablePointer<CChar>?] = storage.map { Optional($0) }
        pointers.append(nil)
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress) }
    }

    private static func waitStatus(from info: siginfo_t) -> Int32 {
        info.si_code == CLD_EXITED
            ? info.si_status << 8
            : info.si_status & 0x7f
    }

    private static func signalOwnedProcess(_ identifier: pid_t, signal: Int32) {
        // The normal case is the atomic runner-owned group. Also signal the
        // unreaped leader PID itself in case the executable deliberately moved
        // to a different group/session. The still-owned child identity makes
        // the direct signal immune to PID reuse. A fully daemonized grandchild
        // that creates a new session is outside this ownership boundary.
        _ = kill(-identifier, signal)
        _ = kill(identifier, signal)
    }

    private static func reap(_ identifier: pid_t) {
        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(identifier, &status, 0)
        } while result == -1 && errno == EINTR
    }

    private static func exitedNormally(_ status: Int32) -> Bool {
        status & 0x7f == 0
    }

    private static func exitCode(_ status: Int32) -> Int32 {
        (status >> 8) & 0xff
    }

    private static func terminationCode(_ status: Int32) -> Int32 {
        exitedNormally(status) ? exitCode(status) : status & 0x7f
    }
}
