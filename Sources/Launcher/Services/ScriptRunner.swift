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
}

final class ProcessScriptRunner: ScriptRunning {
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

        /// Left after `waitid(..., WNOWAIT)` has captured the leader's
        /// status without reaping it. Delayed cancellation cleanup waits for
        /// this before reaping, so the zombie anchors the PID/PGID identity
        /// until the group-wide escalation has been sent.
        let exitObserved = DispatchGroup()
        private let cleanupLock = NSLock()
        private var cancellationCleanupScheduled = false

        init(identifier: pid_t, outputFD: Int32) {
            self.identifier = identifier
            self.outputFD = outputFD
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
    private var pendingOutput = ""
    private var flushScheduled = false
    private var onOutput: ((String) -> Void)?
    private var onCompletion: ((ScriptRunResult) -> Void)?

    private static let flushInterval: DispatchTimeInterval = .milliseconds(80)
    private static let killGracePeriod: DispatchTimeInterval = .seconds(2)
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
        let identifier: UInt64? = stateQueue.sync {
            guard !isActive else { return nil }
            runIdentifier &+= 1
            isActive = true
            cancelRequested = false
            spawnedProcess = nil
            outputFD = -1
            outputSource = nil
            decoder = UTF8StreamDecoder()
            pendingOutput = ""
            flushScheduled = false
            // Silent scripts still need their pipe drained so they cannot block,
            // but retaining no callback also lets the read path skip UTF-8
            // decoding, String growth, coalescing timers, and main-queue work.
            self.onOutput = command.mode == .silent ? nil : onOutput
            self.onCompletion = onCompletion
            return runIdentifier
        }
        guard let identifier else { return false }

        environmentResolver { [weak self] environment in
            guard let self else { return }
            stateQueue.async {
                self.startProcess(
                    command,
                    arguments: arguments,
                    environment: environment,
                    identifier: identifier
                )
            }
        }
        return true
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

    private func scheduleCancellationCleanup(_ process: SpawnedProcess) {
        guard process.beginCancellationCleanup() else { return }
        Self.signalOwnedProcess(process.identifier, signal: SIGTERM)
        waitQueue.asyncAfter(deadline: .now() + Self.killGracePeriod) {
            Self.signalOwnedProcess(process.identifier, signal: SIGKILL)
            process.exitObserved.wait()
            Self.reap(process.identifier)
        }
    }

    // MARK: - Process lifecycle (on stateQueue)

    private func startProcess(
        _ command: ScriptCommand,
        arguments: [String],
        environment: [String: String],
        identifier: UInt64
    ) {
        guard isActive, runIdentifier == identifier, !cancelRequested else { return }

        switch Self.spawn(command, arguments: arguments, environment: environment) {
        case let .failure(errorCode):
            finish(
                .failedToStart(String(cString: strerror(errorCode))),
                identifier: identifier
            )
        case let .success(spawned):
            spawnedProcess = spawned
            outputFD = spawned.outputFD

            let source = DispatchSource.makeReadSource(fileDescriptor: spawned.outputFD, queue: stateQueue)
            source.setEventHandler { [weak self] in
                self?.readAvailableOutput(identifier: identifier)
            }
            source.setCancelHandler {
                _ = Darwin.close(spawned.outputFD)
            }
            outputSource = source
            source.resume()

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
        appendPending(decoder.flushRemainder())
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
        appendPending(decoder.decode(data))
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
        _ command: ScriptCommand,
        arguments: [String],
        environment: [String: String]
    ) -> SpawnResult {
        let isExecutable = FileManager.default.isExecutableFile(atPath: command.url.path)
        let executable = isExecutable ? command.url.path : "/bin/bash"
        let childArguments = isExecutable ? arguments : [command.url.path] + arguments
        let argv = [executable] + childArguments
        let environmentEntries = environment.map { "\($0.key)=\($0.value)" }.sorted()

        var descriptors = [Int32](repeating: -1, count: 2)
        let pipeResult = descriptors.withUnsafeMutableBufferPointer { pipe($0.baseAddress!) }
        guard pipeResult == 0 else { return .failure(errno) }
        let readFD = descriptors[0]
        let writeFD = descriptors[1]

        func closeDescriptors() {
            if readFD >= 0 { _ = Darwin.close(readFD) }
            if writeFD >= 0 { _ = Darwin.close(writeFD) }
        }

        let readFlags = fcntl(readFD, F_GETFL)
        if readFlags != -1 { _ = fcntl(readFD, F_SETFL, readFlags | O_NONBLOCK) }
        _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeFD, F_SETFD, FD_CLOEXEC)

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

        setupError = posix_spawn_file_actions_adddup2(&fileActions, writeFD, STDOUT_FILENO)
        if setupError == 0 {
            setupError = posix_spawn_file_actions_adddup2(&fileActions, writeFD, STDERR_FILENO)
        }
        if setupError == 0 {
            setupError = posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        }
        if setupError == 0 {
            setupError = posix_spawn_file_actions_addclose(&fileActions, readFD)
        }
        if setupError == 0 {
            setupError = posix_spawn_file_actions_addclose(&fileActions, writeFD)
        }
        if setupError == 0 {
            setupError = command.url.deletingLastPathComponent().path.withCString {
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
        let spawnError = executable.withCString { executablePointer in
            withMutableCStringArray(argv) { argumentPointers in
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

        _ = Darwin.close(writeFD)
        return .success(SpawnedProcess(identifier: childPID, outputFD: readFD))
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
