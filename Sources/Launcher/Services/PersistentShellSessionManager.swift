import Darwin
import Foundation

/// Stable identity for one independently persistent shell session.
///
/// A session can execute many foreground commands over its lifetime. Its
/// identity therefore outlives any individual child process launched by the
/// shell.
struct ShellSessionID: Hashable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// Identifies one asynchronous completion request so stale results can never
/// replace a newer shell draft.
struct ShellCompletionRequestID: Hashable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

enum ShellSessionPhase: Equatable {
    case starting
    case ready
    case foreground
    case closing
}

/// State changes emitted by a persistent shell's private control channel.
enum ShellSessionEvent: Equatable {
    case ready(cwd: String)
    case foregroundStarted(command: String)
    case foregroundFinished(result: ScriptRunResult, cwd: String)
    case closed(ScriptRunResult)
}

/// Candidate strings replace `replacementRange`, expressed as UTF-16 offsets
/// into the input passed to `requestCompletions`.
struct ShellCompletionResult: Equatable {
    let requestID: ShellCompletionRequestID
    let replacementRange: Range<Int>
    let candidates: [String]
}

protocol PersistentShellSessionManaging: AnyObject {
    /// Thread-safe snapshot of sessions that have been accepted but not closed.
    var activeSessionIDs: Set<ShellSessionID> { get }

    /// Starts an interactive shell session. Output and events are delivered on
    /// the main queue and are tagged with the originating session identity.
    @discardableResult
    func startSession(
        id: ShellSessionID,
        onOutput: @escaping (ShellSessionID, String) -> Void,
        onEvent: @escaping (ShellSessionID, ShellSessionEvent) -> Void
    ) -> Bool

    /// Submits a command while the session is at its shell prompt.
    @discardableResult
    func submitCommand(_ command: String, to id: ShellSessionID) -> Bool

    /// Sends one newline-terminated input record to the foreground process.
    @discardableResult
    func sendInputLine(_ input: String, to id: ShellSessionID) -> Bool

    /// Sends an interrupt to the current foreground process without closing the
    /// persistent shell. Repeated calls must remain meaningful.
    func interruptForeground(in id: ShellSessionID)

    /// Requests shell-native command/path completion while the session is ready.
    func requestCompletions(
        input: String,
        cursorUTF16: Int,
        in id: ShellSessionID,
        requestID: ShellCompletionRequestID,
        completion: @escaping (ShellSessionID, ShellCompletionResult) -> Void
    )

    /// Gracefully closes one session. Its eventual `.closed` event is the source
    /// of truth for removing model state.
    func closeSession(_ id: ShellSessionID)

    /// Immediately terminates every owned process during application shutdown.
    func terminateAllImmediately()
}

/// PTY-backed implementation used by the application.
///
/// `openpty` is safe in a multithreaded process; `forkpty` is not.  The parent
/// therefore opens the terminal and uses `posix_spawn` to start a tiny mode of
/// the Launcher executable.  That pristine helper can safely create a session,
/// acquire the terminal, and `execve` the user's login shell.
final class ProcessPersistentShellSessionManager: PersistentShellSessionManaging {
    private struct UTF8Decoder {
        var carry: [UInt8] = []

        mutating func decode(_ bytes: ArraySlice<UInt8>) -> String {
            carry.append(contentsOf: bytes)
            guard !carry.isEmpty else { return "" }
            var validCount = carry.count
            while validCount > 0, validCount > carry.count - 4 {
                if String(bytes: carry[..<validCount], encoding: .utf8) != nil { break }
                validCount -= 1
            }
            guard validCount > 0 else { return "" }
            let result = String(decoding: carry[..<validCount], as: UTF8.self)
            carry.removeFirst(validCount)
            return result
        }

        mutating func finish() -> String {
            defer { carry.removeAll() }
            return String(decoding: carry, as: UTF8.self)
        }
    }

    private enum Phase {
        case starting
        case ready
        case foreground
        case closing
    }

    private final class Session {
        let id: ShellSessionID
        let pid: pid_t
        let masterFD: Int32
        let controlFD: Int32
        let commandFD: Int32
        let onOutput: (ShellSessionID, String) -> Void
        let onEvent: (ShellSessionID, ShellSessionEvent) -> Void
        var phase: Phase = .starting
        var cwd: String
        var path: String
        var home: String
        var shellCommandNames: Set<String> = []
        var controlBuffer = Data()
        var sanitizer = TerminalOutputSanitizer()
        var decoder = UTF8Decoder()
        var pendingOutput = ""
        var outputFlushScheduled = false
        var outputSource: DispatchSourceRead?
        var controlSource: DispatchSourceRead?
        var processSource: DispatchSourceProcess?
        var closeRequested = false
        var closedResultOverride: ScriptRunResult?
        var interruptRequested = false
        var interruptSignalPending = false
        var commandBaselineDescendants: Set<pid_t> = []
        var currentCommand: String?

        init(
            id: ShellSessionID,
            pid: pid_t,
            masterFD: Int32,
            controlFD: Int32,
            commandFD: Int32,
            cwd: String,
            path: String,
            home: String,
            onOutput: @escaping (ShellSessionID, String) -> Void,
            onEvent: @escaping (ShellSessionID, ShellSessionEvent) -> Void
        ) {
            self.id = id
            self.pid = pid
            self.masterFD = masterFD
            self.controlFD = controlFD
            self.commandFD = commandFD
            self.cwd = cwd
            self.path = path
            self.home = home
            self.onOutput = onOutput
            self.onEvent = onEvent
        }
    }

    private struct SpawnedShell {
        let pid: pid_t
        let masterFD: Int32
        let controlFD: Int32
        let commandFD: Int32
    }

    private let queue = DispatchQueue(label: "launcher.persistentShell.state", qos: .userInitiated)
    private let completionQueue = DispatchQueue(
        label: "launcher.persistentShell.completion",
        qos: .utility,
        attributes: .concurrent
    )
    private let shellPath: String
    private let initialEnvironment: [String: String]
    private let workingDirectory: URL
    private let helperExecutablePath: String
    private let startupTimeout: TimeInterval
    private var sessions: [ShellSessionID: Session] = [:]
    private static let outputFlushInterval: DispatchTimeInterval = .milliseconds(50)
    private static let maximumPendingOutputCharacters = 100_000
    /// Baseline zsh builtins available without searching PATH. Keeping this
    /// local avoids evaluating user-controlled shell configuration merely to
    /// offer completion candidates.
    private static let zshBuiltinCommandNames: Set<String> = [
        "-", ".", ":", "[", "alias", "autoload", "bg", "bindkey", "break", "builtin", "bye",
        "cd", "chdir", "command", "compadd", "comparguments", "compcall", "compctl",
        "compdescribe", "compfiles", "compgroups", "compquote", "compset", "comptags", "comptry",
        "compvalues", "continue", "declare", "dirs", "disable", "disown", "echo", "echotc",
        "echoti", "emulate", "enable", "eval", "exec", "exit", "export", "false", "fc", "fg",
        "float", "functions", "getln", "getopts", "hash", "history", "integer", "jobs", "kill",
        "let", "limit", "local", "log", "logout", "noglob", "popd", "print", "printf", "private",
        "pushd", "pushln", "pwd", "r", "read", "readonly", "rehash", "return", "sched", "set",
        "setopt", "shift", "source", "suspend", "test", "times", "trap", "true", "ttyctl", "type",
        "typeset", "ulimit", "umask", "unalias", "unfunction", "unhash", "unlimit", "unset",
        "unsetopt", "vared", "wait", "whence", "where", "which", "zcompile", "zformat", "zle",
        "zmodload", "zparseopts", "zregexparse", "zstyle",
    ]
    /// Complete user records must fit comfortably below Darwin's canonical tty
    /// queue. Acceptance is decided before the first byte reaches the PTY.
    static let maximumTerminalLineBytes = 512
    static let maximumCommandBytes = 64 * 1_024

    init(
        // The private wrapper intentionally targets zsh. Selecting an arbitrary
        // `$SHELL` here would make fish/tcsh installations start a dead session.
        shellPath: String = "/bin/zsh",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        helperExecutablePath: String? = nil,
        startupTimeout: TimeInterval = 8
    ) {
        self.shellPath = shellPath
        var environment = environment
        environment["TERM"] = "dumb"
        environment["NO_COLOR"] = "1"
        environment["CLAUDE_AX_SCREEN_READER"] = "1"
        // Unit-test injection variables must never be inherited by the helper:
        // doing so would load the test bundle again in every spawned shell.
        environment.removeValue(forKey: "XCInjectBundleInto")
        environment.removeValue(forKey: "XCTestConfigurationFilePath")
        environment.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
        self.initialEnvironment = environment
        self.workingDirectory = workingDirectory
        self.helperExecutablePath = helperExecutablePath
            ?? Bundle.main.executableURL?.path
            ?? ProcessInfo.processInfo.arguments[0]
        self.startupTimeout = max(0.01, startupTimeout)
    }

    deinit {
        terminateAllImmediately()
    }

    var activeSessionIDs: Set<ShellSessionID> {
        queue.sync { Set(sessions.keys) }
    }

    @discardableResult
    func startSession(
        id: ShellSessionID,
        onOutput: @escaping (ShellSessionID, String) -> Void,
        onEvent: @escaping (ShellSessionID, ShellSessionEvent) -> Void
    ) -> Bool {
        queue.sync {
            guard sessions[id] == nil else { return false }
            let environment = initialEnvironment
            guard let spawned = Self.spawn(
                executable: helperExecutablePath,
                shell: shellPath,
                directory: workingDirectory,
                environment: environment
            ) else { return false }

            let session = Session(
                id: id,
                pid: spawned.pid,
                masterFD: spawned.masterFD,
                controlFD: spawned.controlFD,
                commandFD: spawned.commandFD,
                cwd: workingDirectory.path,
                path: environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
                home: environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path,
                onOutput: onOutput,
                onEvent: onEvent
            )
            session.shellCommandNames = Self.zshBuiltinCommandNames
            sessions[id] = session
            installSources(for: session)
            sendInitialization(to: session)
            scheduleStartupTimeout(for: session)
            return true
        }
    }

    @discardableResult
    func submitCommand(_ command: String, to id: ShellSessionID) -> Bool {
        queue.sync {
            guard let session = sessions[id], session.phase == .ready else { return false }
            guard !command.contains("\0"),
                  command.utf8.count <= Self.maximumCommandBytes else { return false }
            let encoded = Data(command.utf8).base64EncodedString()
            session.phase = .foreground
            session.interruptRequested = false
            session.currentCommand = command
            session.commandBaselineDescendants = Set(Self.descendantPIDs(of: session.pid))
            // Only this constant trigger crosses the canonical terminal. The
            // potentially secret/large command travels through private FD4.
            guard write("__launcher_run\n", to: session.masterFD),
                  write(encoded + "\n", to: session.commandFD) else {
                session.phase = .ready
                session.closedResultOverride = .failedToStart("Command transport failed")
                _ = kill(-session.pid, SIGKILL)
                _ = kill(session.pid, SIGKILL)
                return false
            }
            return true
        }
    }

    @discardableResult
    func sendInputLine(_ input: String, to id: ShellSessionID) -> Bool {
        queue.sync {
            guard let session = sessions[id], session.phase == .foreground else { return false }
            guard !input.contains("\0"), !input.contains("\n"), !input.contains("\r"),
                  input.utf8.count + 1 <= Self.maximumTerminalLineBytes else { return false }
            return write(input + "\r", to: session.masterFD)
        }
    }

    func interruptForeground(in id: ShellSessionID) {
        queue.async { [self] in
            guard let session = self.sessions[id], session.phase == .foreground else { return }
            guard !session.interruptSignalPending else { return }
            session.interruptRequested = true
            session.interruptSignalPending = true
            self.queue.asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self, weak session] in
                guard let self, let session, self.sessions[session.id] === session else { return }
                session.interruptSignalPending = false
            }
            self.resolveAndSignalInterrupt(session, attemptsRemaining: 40)
        }
    }

    func requestCompletions(
        input: String,
        cursorUTF16: Int,
        in id: ShellSessionID,
        requestID: ShellCompletionRequestID,
        completion: @escaping (ShellSessionID, ShellCompletionResult) -> Void
    ) {
        queue.async { [self] in
            guard let session = self.sessions[id], session.phase == .ready else {
                DispatchQueue.main.async {
                    completion(id, ShellCompletionResult(
                        requestID: requestID,
                        replacementRange: cursorUTF16..<cursorUTF16,
                        candidates: []
                    ))
                }
                return
            }
            let cwd = session.cwd
            let path = session.path
            let home = session.home
            let shellCommandNames = session.shellCommandNames
            self.completionQueue.async { [weak self, weak session] in
                let result = Self.completions(
                    input: input,
                    cursorUTF16: cursorUTF16,
                    cwd: cwd,
                    path: path,
                    home: home,
                    shellCommandNames: shellCommandNames,
                    requestID: requestID
                )
                guard let self, let session else { return }
                self.queue.async {
                    guard self.sessions[id] === session, session.phase == .ready else { return }
                    DispatchQueue.main.async { completion(id, result) }
                }
            }
        }
    }

    func closeSession(_ id: ShellSessionID) {
        queue.async {
            guard let session = self.sessions[id], !session.closeRequested else { return }
            session.closeRequested = true
            session.phase = .closing
            let foregroundGroup = tcgetpgrp(session.masterFD)
            if foregroundGroup > 0, foregroundGroup != session.pid {
                _ = kill(-foregroundGroup, SIGTERM)
            } else if foregroundGroup == session.pid {
                _ = self.write("exit\n", to: session.masterFD)
            }
            self.scheduleEscalation(for: session)
        }
    }

    func terminateAllImmediately() {
        queue.sync {
            for session in sessions.values {
                session.closeRequested = true
                session.phase = .closing
                Self.signalForeground(of: session, signal: SIGKILL)
                Self.signalDescendants(of: session.pid, signal: SIGKILL)
                _ = kill(-session.pid, SIGKILL)
                _ = kill(session.pid, SIGKILL)
            }
        }
    }

    // MARK: Child helper

    static let helperArgument = "--launcher-persistent-shell-helper"

    /// Called by the executable entry point before AppKit/SwiftUI starts.
    static func runHelperIfRequested() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.count == 3, arguments[1] == helperArgument else { return false }
        let shell = arguments[2]

        guard setsid() != -1 else { _exit(126) }
        guard ioctl(STDIN_FILENO, TIOCSCTTY, 0) != -1 else { _exit(126) }
        _ = tcsetpgrp(STDIN_FILENO, getpgrp())

        var defaults = sigset_t()
        sigemptyset(&defaults)
        pthread_sigmask(SIG_SETMASK, &defaults, nil)
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
        signal(SIGHUP, SIG_DFL)
        signal(SIGQUIT, SIG_DFL)

        let argv0 = "-" + URL(fileURLWithPath: shell).lastPathComponent
        let storage = [strdup(argv0), strdup("-i"), nil]
        defer { storage.compactMap { $0 }.forEach { free($0) } }
        var argv = storage
        shell.withCString { executable in
            argv.withUnsafeMutableBufferPointer { pointers in
                _ = execve(executable, pointers.baseAddress!, environ)
            }
        }
        _exit(127)
    }

    // MARK: Session plumbing

    private func installSources(for session: Session) {
        let output = DispatchSource.makeReadSource(fileDescriptor: session.masterFD, queue: queue)
        output.setEventHandler { [weak self, weak session] in
            guard let self, let session, self.sessions[session.id] === session else { return }
            self.consumeOutput(from: session)
        }
        output.setCancelHandler { _ = Darwin.close(session.masterFD) }
        session.outputSource = output

        let control = DispatchSource.makeReadSource(fileDescriptor: session.controlFD, queue: queue)
        control.setEventHandler { [weak self, weak session] in
            guard let self, let session, self.sessions[session.id] === session else { return }
            self.consumeControl(from: session)
        }
        control.setCancelHandler { _ = Darwin.close(session.controlFD) }
        session.controlSource = control

        let process = DispatchSource.makeProcessSource(
            identifier: session.pid,
            eventMask: .exit,
            queue: queue
        )
        process.setEventHandler { [weak self, weak session] in
            guard let self, let session else { return }
            self.processExited(session)
        }
        session.processSource = process
        output.resume()
        control.resume()
        process.resume()
    }

    private func sendInitialization(to session: Session) {
        // The command is constant and contains no user data or secrets.  User
        // commands are subsequently base64 arguments and never written to disk.
        let script = """
        unsetopt PROMPT_CR PROMPT_SP ZLE 2>/dev/null
        PS1=''; PS2=''
        __launcher_emit() { /usr/bin/printf '%s\\n' "$1" >&3 }
        __launcher_ready() { __launcher_emit $'R\\t'"$(/usr/bin/printf '%s' "$PWD" | /usr/bin/base64)"$'\\t'"$(/usr/bin/printf '%s' "$PATH" | /usr/bin/base64)" }
        __launcher_finish() {
          local __l_status="$1" __l_cwd __l_path __l_home
          __l_cwd="$(/usr/bin/printf '%s' "$PWD" | /usr/bin/base64)"
          __l_path="$(/usr/bin/printf '%s' "$PATH" | /usr/bin/base64)"
          __l_home="$(/usr/bin/printf '%s' "$HOME" | /usr/bin/base64)"
          __launcher_emit $'F\\t'"$__l_status"$'\\t'"$__l_cwd"$'\\t'"$__l_path"$'\\t'"$__l_home"
        }
        __launcher_run() {
          local __l_b64 __l_cmd __l_status=''
          IFS= read -r __l_b64 <&4 || return 125
          __l_cmd="$(/usr/bin/printf '%s' "$__l_b64" | /usr/bin/base64 -D)"
          __launcher_emit 'S'
          {
            eval "$__l_cmd" 3>&- 4>&-
            __l_status=$?
          } always {
            [[ -n "$__l_status" ]] || __l_status=130
            __launcher_finish "$__l_status"
          }
        }
        /bin/stty -echo
        precmd_functions+=(__launcher_ready)
        __launcher_ready
        """ + "\n"
        guard write(script, to: session.masterFD) else {
            session.closedResultOverride = .failedToStart("Could not initialize the shell session.")
            session.closeRequested = true
            session.phase = .closing
            _ = kill(-session.pid, SIGKILL)
            _ = kill(session.pid, SIGKILL)
            return
        }
    }

    private func scheduleStartupTimeout(for session: Session) {
        queue.asyncAfter(deadline: .now() + startupTimeout) { [weak self, weak session] in
            guard let self, let session,
                  self.sessions[session.id] === session,
                  session.phase == .starting else { return }

            // Startup files are arbitrary user code. A prompt, setup wizard,
            // blocking read, or exec can consume the injected bootstrap before
            // it establishes the private control protocol. Bound that state so
            // the model can never retain an uncloseable Starting Shell row.
            session.closedResultOverride = .failedToStart("Shell startup timed out.")
            session.closeRequested = true
            session.phase = .closing
            Self.signalForeground(of: session, signal: SIGTERM)
            Self.signalDescendants(of: session.pid, signal: SIGTERM)
            _ = kill(-session.pid, SIGTERM)
            _ = kill(session.pid, SIGTERM)
            self.queue.asyncAfter(deadline: .now() + 1) { [weak self, weak session] in
                guard let self, let session, self.sessions[session.id] === session else { return }
                Self.signalForeground(of: session, signal: SIGKILL)
                Self.signalDescendants(of: session.pid, signal: SIGKILL)
                _ = kill(-session.pid, SIGKILL)
                _ = kill(session.pid, SIGKILL)
            }
        }
    }

    private func consumeOutput(from session: Session) {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        var iterations = 0
        while iterations < 16 {
            iterations += 1
            let count = Darwin.read(session.masterFD, &bytes, bytes.count)
            if count > 0 {
                let raw = session.decoder.decode(bytes[..<count])
                let clean = session.sanitizer.sanitize(raw)
                if session.phase != .starting { enqueueOutput(clean, for: session) }
            } else if count == -1, errno == EINTR {
                continue
            } else {
                break
            }
        }
    }

    private func consumeControl(from session: Session) {
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(session.controlFD, &bytes, bytes.count)
            if count > 0 {
                session.controlBuffer.append(bytes, count: count)
                while let newline = session.controlBuffer.firstIndex(of: 0x0A) {
                    let line = session.controlBuffer[..<newline]
                    session.controlBuffer.removeSubrange(...newline)
                    handleControl(String(decoding: line, as: UTF8.self), for: session)
                }
            } else if count == -1, errno == EINTR {
                continue
            } else {
                break
            }
        }
    }

    private func handleControl(_ line: String, for session: Session) {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard let kind = fields.first else { return }
        switch kind {
        case "R" where fields.count >= 3:
            guard let cwd = decode64(fields[1]), let path = decode64(fields[2]) else { return }
            // The shell writes its startup/banner/initialization echo before R,
            // but the PTY and control pipe have independent dispatch sources.
            // Drain that already-produced terminal data while still starting.
            consumeOutput(from: session)
            let decodedTail = session.decoder.finish()
            let readableTail = session.sanitizer.sanitize(decodedTail) + session.sanitizer.finish()
            let previousCWD = session.cwd
            session.cwd = cwd
            session.path = path
            if session.phase == .starting {
                session.phase = .ready
                emit(.ready(cwd: cwd), for: session)
            } else if session.phase == .foreground, session.interruptRequested {
                session.interruptRequested = false
                session.interruptSignalPending = false
                enqueueOutput(readableTail, for: session)
                flushOutput(for: session)
                session.phase = .ready
                emit(.foregroundFinished(result: .cancelled, cwd: cwd), for: session)
            } else if session.phase == .ready, cwd != previousCWD {
                // Interrupt fallback can observe prompt ownership before the
                // authoritative R frame arrives. Publish its cwd correction so
                // a command such as `cd /tmp; sleep 30` cannot leave the model
                // displaying the session's previous directory.
                emit(.ready(cwd: cwd), for: session)
            }

        case "S":
            let command = session.currentCommand ?? ""
            emit(.foregroundStarted(command: command), for: session)

        case "F" where fields.count >= 4:
            guard session.phase == .foreground else { return }
            guard let status = Int32(fields[1]),
                  let cwd = decode64(fields[2]),
                  let path = decode64(fields[3]) else { return }
            if fields.indices.contains(4), let home = decode64(fields[4]) {
                session.home = home
            }
            session.cwd = cwd
            session.path = path
            // POSIX writes command output before the control frame, but the two
            // descriptors have independent dispatch sources. Drain the PTY and
            // enqueue its final coalesced chunk before the finished event.
            consumeOutput(from: session)
            enqueueOutput(session.sanitizer.sanitize(session.decoder.finish()), for: session)
            enqueueOutput(session.sanitizer.finish(), for: session)
            flushOutput(for: session)
            let result: ScriptRunResult
            if status == 130 {
                result = .cancelled
            } else if status == 0 {
                result = .success
            } else {
                result = .failure(exitCode: status)
            }
            emit(.foregroundFinished(result: result, cwd: cwd), for: session)
            session.interruptRequested = false
            session.interruptSignalPending = false
            session.currentCommand = nil
            if session.closeRequested {
                _ = write("exit\n", to: session.masterFD)
            } else {
                session.phase = .ready
            }

        default:
            break
        }
    }

    private func processExited(_ session: Session) {
        guard sessions[session.id] === session else { return }
        var status: Int32 = 0
        var waited: pid_t
        repeat { waited = waitpid(session.pid, &status, 0) } while waited == -1 && errno == EINTR
        // Exit notification can race the read sources. Drain both descriptors
        // while they still belong to this generation, then enqueue output and
        // control-derived events before `.closed`.
        consumeOutput(from: session)
        consumeControl(from: session)
        enqueueOutput(session.sanitizer.sanitize(session.decoder.finish()), for: session)
        enqueueOutput(session.sanitizer.finish(), for: session)
        flushOutput(for: session)
        sessions.removeValue(forKey: session.id)
        session.outputSource?.cancel()
        session.controlSource?.cancel()
        session.processSource?.cancel()
        _ = Darwin.close(session.commandFD)
        let result: ScriptRunResult
        if let closedResultOverride = session.closedResultOverride {
            result = closedResultOverride
        } else if session.closeRequested {
            result = .success
        } else if waited == -1 {
            result = .failedToStart(String(cString: strerror(errno)))
        } else if status & 0x7f == 0, ((status >> 8) & 0xff) == 0 {
            result = .success
        } else {
            let code = status & 0x7f == 0 ? (status >> 8) & 0xff : status & 0x7f
            result = .failure(exitCode: code)
        }
        DispatchQueue.main.async { session.onEvent(session.id, .closed(result)) }
    }

    private func emit(_ event: ShellSessionEvent, for session: Session) {
        DispatchQueue.main.async { [weak session] in
            guard let session else { return }
            session.onEvent(session.id, event)
        }
    }

    private func enqueueOutput(_ output: String, for session: Session) {
        guard !output.isEmpty else { return }
        session.pendingOutput += output
        if session.pendingOutput.count > Self.maximumPendingOutputCharacters {
            session.pendingOutput = String(
                session.pendingOutput.suffix(Self.maximumPendingOutputCharacters)
            )
        }
        guard !session.outputFlushScheduled else { return }
        session.outputFlushScheduled = true
        queue.asyncAfter(deadline: .now() + Self.outputFlushInterval) { [weak self, weak session] in
            guard let self, let session else { return }
            self.flushOutput(for: session)
        }
    }

    private func flushOutput(for session: Session) {
        session.outputFlushScheduled = false
        guard !session.pendingOutput.isEmpty else { return }
        let output = session.pendingOutput
        session.pendingOutput = ""
        DispatchQueue.main.async { [weak session] in
            guard let session else { return }
            session.onOutput(session.id, output)
        }
    }

    private func scheduleEscalation(for session: Session) {
        queue.asyncAfter(deadline: .now() + 1) { [weak self, weak session] in
            guard let self, let session, self.sessions[session.id] === session else { return }
            Self.signalForeground(of: session, signal: SIGTERM)
            Self.signalDescendants(of: session.pid, signal: SIGTERM)
            _ = kill(-session.pid, SIGTERM)
            _ = kill(session.pid, SIGTERM)
            self.queue.asyncAfter(deadline: .now() + 1) { [weak self, weak session] in
                guard let self, let session, self.sessions[session.id] === session else { return }
                Self.signalForeground(of: session, signal: SIGKILL)
                Self.signalDescendants(of: session.pid, signal: SIGKILL)
                _ = kill(-session.pid, SIGKILL)
                _ = kill(session.pid, SIGKILL)
            }
        }
    }

    private func write(_ text: String, to descriptor: Int32) -> Bool {
        let data = Data(text.utf8)
        return data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return true }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), rawBuffer.count - offset)
                if count > 0 { offset += count; continue }
                if count == -1, errno == EINTR { continue }
                if count == -1, errno == EAGAIN || errno == EWOULDBLOCK {
                    var writable = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    if poll(&writable, 1, 1_000) > 0 { continue }
                }
                return false
            }
            return true
        }
    }

    private func decode64(_ encoded: String) -> String? {
        Data(base64Encoded: encoded).map { String(decoding: $0, as: UTF8.self) }
    }

    private func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func signalForeground(of session: Session, signal: Int32) {
        let foregroundGroup = foregroundGroup(of: session)
        if foregroundGroup > 0 { _ = kill(-foregroundGroup, signal) }
    }

    private static func foregroundGroup(of session: Session) -> pid_t {
        tcgetpgrp(session.masterFD)
    }

    private static func signalDescendants(of parent: pid_t, signal: Int32) {
        for child in descendantPIDs(of: parent).reversed() { _ = kill(child, signal) }
    }

    private static func descendantPIDs(of parent: pid_t) -> [pid_t] {
        var children = [pid_t](repeating: 0, count: 128)
        let count = children.withUnsafeMutableBytes {
            proc_listchildpids(parent, $0.baseAddress, Int32($0.count))
        }
        guard count > 0 else { return [] }
        var result: [pid_t] = []
        let pidCount = Int(count) / MemoryLayout<pid_t>.stride
        for child in children.prefix(min(pidCount, children.count)) where child > 0 {
            result.append(child)
            result.append(contentsOf: descendantPIDs(of: child))
        }
        return result
    }

    private func pollForShellReadyAfterInterrupt(_ session: Session, attemptsRemaining: Int) {
        queue.asyncAfter(deadline: .now() + .milliseconds(25)) { [weak self, weak session] in
            guard let self, let session,
                  self.sessions[session.id] === session,
                  session.phase == .foreground,
                  session.interruptRequested else { return }
            if tcgetpgrp(session.masterFD) == session.pid {
                // The terminal, rather than a timer alone, is the readiness
                // proof. A signal-handling Claude/TUI keeps its own foreground
                // group and therefore remains foreground here.
                self.consumeOutput(from: session)
                self.enqueueOutput(session.sanitizer.sanitize(session.decoder.finish()), for: session)
                self.enqueueOutput(session.sanitizer.finish(), for: session)
                self.flushOutput(for: session)
                session.interruptRequested = false
                session.interruptSignalPending = false
                session.phase = .ready
                self.emit(.foregroundFinished(result: .cancelled, cwd: session.cwd), for: session)
            } else if attemptsRemaining > 1 {
                self.pollForShellReadyAfterInterrupt(session, attemptsRemaining: attemptsRemaining - 1)
            }
        }
    }

    private func resolveAndSignalInterrupt(_ session: Session, attemptsRemaining: Int) {
        queue.asyncAfter(deadline: .now() + .milliseconds(25)) { [weak self, weak session] in
            guard let self, let session,
                  self.sessions[session.id] === session,
                  session.phase == .foreground,
                  session.interruptRequested else { return }
            let group = Self.foregroundGroup(of: session)
            if group > 0, group != session.pid {
                let groupResult = kill(-group, SIGINT)
                let directResult = groupResult == 0 ? 0 : kill(group, SIGINT)
                if groupResult == 0 || directResult == 0 {
                    session.interruptSignalPending = false
                    self.pollForShellReadyAfterInterrupt(session, attemptsRemaining: 40)
                    return
                }
            }

            let newDescendants = Set(Self.descendantPIDs(of: session.pid))
                .subtracting(session.commandBaselineDescendants)
            var signalledChild = false
            for child in newDescendants where kill(child, SIGINT) == 0 { signalledChild = true }
            if signalledChild {
                session.interruptSignalPending = false
                self.pollForShellReadyAfterInterrupt(session, attemptsRemaining: 40)
            } else if attemptsRemaining > 37 {
                // Skip transient decoder/command-substitution children created
                // between the S frame and the actual foreground command.
                self.resolveAndSignalInterrupt(session, attemptsRemaining: attemptsRemaining - 1)
            } else {
                _ = kill(-session.pid, SIGINT)
                session.interruptSignalPending = false
                self.pollForShellReadyAfterInterrupt(session, attemptsRemaining: 40)
            }
        }
    }

    // MARK: Completion

    private struct CompletionTokenContext {
        let start: Int
        let token: String
        let openingQuote: Character?
        let isCommand: Bool
    }

    /// Finds the shell word at the caret while retaining just enough grammar
    /// to distinguish commands from arguments and redirection targets. This is
    /// intentionally not a shell evaluator: quotes and escapes are only used
    /// as lexical boundaries, and no user text is executed during completion.
    private static func completionTokenContext(
        utf16: [UInt16],
        cursor: Int
    ) -> CompletionTokenContext {
        var start = 0
        var index = 0
        var quote: UInt16?
        var escaped = false
        var hasCurrentToken = false
        var expectsCommand = true
        var expectsRedirectionTarget = false

        func isAssignmentWord(_ units: ArraySlice<UInt16>) -> Bool {
            guard let first = units.first,
                  first == 0x5F || (0x41...0x5A).contains(first) || (0x61...0x7A).contains(first)
            else { return false }
            for value in units.dropFirst() {
                if value == 0x3D { return true }
                guard value == 0x5F
                    || (0x30...0x39).contains(value)
                    || (0x41...0x5A).contains(value)
                    || (0x61...0x7A).contains(value)
                else { return false }
            }
            return false
        }

        func isFileDescriptorWord(_ units: ArraySlice<UInt16>) -> Bool {
            !units.isEmpty && units.allSatisfy { (0x30...0x39).contains($0) }
        }

        func finishCurrentWord(at end: Int) {
            guard hasCurrentToken else { return }
            let units = utf16[start..<end]
            if expectsRedirectionTarget {
                expectsRedirectionTarget = false
            } else if expectsCommand, !isAssignmentWord(units) {
                expectsCommand = false
            }
            hasCurrentToken = false
        }

        while index < cursor {
            let value = utf16[index]
            if escaped {
                escaped = false
                hasCurrentToken = true
                index += 1
                continue
            }
            if value == 0x5C, quote != 0x27 {
                escaped = true
                hasCurrentToken = true
                index += 1
                continue
            }
            if let activeQuote = quote {
                if value == activeQuote { quote = nil }
                hasCurrentToken = true
                index += 1
                continue
            }
            if value == 0x27 || value == 0x22 {
                quote = value
                hasCurrentToken = true
                index += 1
                continue
            }

            if value == 0x0A || value == 0x3B || value == 0x7C
                || (value == 0x26 && !(index + 1 < cursor && utf16[index + 1] == 0x3E))
                || value == 0x28 || value == 0x29 {
                finishCurrentWord(at: index)
                expectsCommand = true
                expectsRedirectionTarget = false
                hasCurrentToken = false
                index += 1
                if index < cursor,
                   (value == 0x7C || value == 0x26),
                   utf16[index] == value {
                    index += 1
                }
                start = index
                continue
            }

            let isAmpersandRedirection = value == 0x26
                && index + 1 < cursor
                && utf16[index + 1] == 0x3E
            if value == 0x3C || value == 0x3E || isAmpersandRedirection {
                if hasCurrentToken {
                    let units = utf16[start..<index]
                    if isFileDescriptorWord(units) {
                        hasCurrentToken = false
                    } else {
                        finishCurrentWord(at: index)
                    }
                }
                expectsRedirectionTarget = true

                if isAmpersandRedirection { index += 1 }
                let direction = utf16[index]
                index += 1
                while index < cursor, utf16[index] == direction { index += 1 }
                if index < cursor, utf16[index] == 0x26 || utf16[index] == 0x7C {
                    index += 1
                }
                start = index
                continue
            }

            if value == 0x20 || value == 0x09 {
                finishCurrentWord(at: index)
                index += 1
                start = index
                continue
            }

            hasCurrentToken = true
            index += 1
        }

        let token = String(decoding: utf16[start..<cursor], as: UTF16.self)
        let openingQuote = token.first.flatMap { $0 == "'" || $0 == "\"" ? $0 : nil }
        let currentIsAssignment = expectsCommand && isAssignmentWord(utf16[start..<cursor])
        return CompletionTokenContext(
            start: start,
            token: token,
            openingQuote: openingQuote,
            isCommand: expectsCommand && !expectsRedirectionTarget && !currentIsAssignment
        )
    }

    private static func completions(
        input: String,
        cursorUTF16: Int,
        cwd: String,
        path: String,
        home: String,
        shellCommandNames: Set<String>,
        requestID: ShellCompletionRequestID
    ) -> ShellCompletionResult {
        let utf16 = Array(input.utf16)
        let cursor = max(0, min(cursorUTF16, utf16.count))
        let context = completionTokenContext(utf16: utf16, cursor: cursor)
        let start = context.start
        let token = context.token
        let openingQuote = context.openingQuote
        let isCommand = context.isCommand
        var unescaped = openingQuote == nil ? token : String(token.dropFirst())
        unescaped = shellUnescape(unescaped, quote: openingQuote)
        var candidates = Set<String>()

        func addFiles(in directory: String, prefix: String, displayedDirectory: String) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
            for name in names where name.hasPrefix(prefix) {
                let full = (directory as NSString).appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory)
                let value = displayedDirectory + name + (isDirectory.boolValue ? "/" : "")
                candidates.insert(shellEscape(value, quote: openingQuote))
            }
        }

        let nsToken = unescaped as NSString
        let hasTrailingSlash = unescaped.hasSuffix("/")
        let directoryPart = hasTrailingSlash ? String(unescaped.dropLast()) : nsToken.deletingLastPathComponent
        let prefix = hasTrailingSlash ? "" : nsToken.lastPathComponent
        if unescaped.contains("/") || !isCommand {
            let displayDirectory: String
            let searchDirectory: String
            if unescaped.hasPrefix("~/"), openingQuote == nil {
                displayDirectory = directoryPart == "~" ? "~/" : directoryPart + "/"
                let relative = directoryPart == "~" ? "" : String(directoryPart.dropFirst(2))
                searchDirectory = relative.isEmpty
                    ? home
                    : (home as NSString).appendingPathComponent(relative)
            } else if unescaped.hasPrefix("/") {
                displayDirectory = directoryPart == "/" ? "/" : directoryPart + "/"
                searchDirectory = directoryPart.isEmpty ? "/" : directoryPart
            } else {
                displayDirectory = directoryPart.isEmpty ? "" : directoryPart + "/"
                searchDirectory = directoryPart.isEmpty
                    ? cwd
                    : (cwd as NSString).appendingPathComponent(directoryPart)
            }
            addFiles(in: searchDirectory, prefix: prefix, displayedDirectory: displayDirectory)
        }
        if isCommand, !unescaped.contains("/") {
            for name in shellCommandNames where name.hasPrefix(unescaped) {
                candidates.insert(shellEscape(name, quote: openingQuote))
            }
            for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
                let entry = String(directory)
                let resolved = entry.isEmpty
                    ? cwd
                    : (entry.hasPrefix("/") ? entry : (cwd as NSString).appendingPathComponent(entry))
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: resolved) else { continue }
                for name in names where name.hasPrefix(unescaped) {
                    let full = (resolved as NSString).appendingPathComponent(name)
                    if FileManager.default.isExecutableFile(atPath: full) {
                        candidates.insert(shellEscape(name, quote: openingQuote))
                    }
                }
            }
        }
        return ShellCompletionResult(
            requestID: requestID,
            replacementRange: start..<cursor,
            candidates: candidates.sorted()
        )
    }

    private static func shellUnescape(_ value: String, quote: Character?) -> String {
        if quote == "'" { return value }
        var result = ""
        var escaped = false
        for character in value {
            if escaped { result.append(character); escaped = false }
            else if character == "\\" { escaped = true }
            else { result.append(character) }
        }
        if escaped { result.append("\\") }
        return result
    }

    private static func shellEscape(_ value: String, quote: Character?) -> String {
        if quote == "'" {
            return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        if quote == "\"" {
            var escaped = value
            for special in ["\\", "\"", "$", "`"] {
                escaped = escaped.replacingOccurrences(of: special, with: "\\" + special)
            }
            return "\"" + escaped + "\""
        }
        if value.contains("\n") || value.contains("\r") {
            return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_./~-"))
        var result = ""
        for scalar in value.unicodeScalars {
            if safe.contains(scalar) { result.unicodeScalars.append(scalar) }
            else { result.append("\\"); result.unicodeScalars.append(scalar) }
        }
        return result
    }

    // MARK: Spawn

    private static func spawn(
        executable: String,
        shell: String,
        directory: URL,
        environment: [String: String]
    ) -> SpawnedShell? {
        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(ws_row: 24, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { return nil }
        var control = [Int32](repeating: -1, count: 2)
        guard control.withUnsafeMutableBufferPointer({ pipe($0.baseAddress!) }) == 0 else {
            _ = Darwin.close(master); _ = Darwin.close(slave); return nil
        }
        let controlRead = control[0]
        let controlWrite = control[1]
        var command = [Int32](repeating: -1, count: 2)
        guard command.withUnsafeMutableBufferPointer({ pipe($0.baseAddress!) }) == 0 else {
            [master, slave, controlRead, controlWrite].forEach { _ = Darwin.close($0) }
            return nil
        }
        let commandRead = command[0]
        let commandWrite = command[1]
        let controlSpawnFD = fcntl(controlWrite, F_DUPFD_CLOEXEC, 10)
        let commandSpawnFD = fcntl(commandRead, F_DUPFD_CLOEXEC, 11)
        guard controlSpawnFD >= 0, commandSpawnFD >= 0 else {
            [master, slave, controlRead, controlWrite, commandRead, commandWrite,
             controlSpawnFD, commandSpawnFD].filter { $0 >= 0 }.forEach { _ = Darwin.close($0) }
            return nil
        }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(controlRead, F_SETFD, FD_CLOEXEC)
        _ = fcntl(commandWrite, F_SETFD, FD_CLOEXEC)
        let masterFlags = fcntl(master, F_GETFL)
        if masterFlags >= 0 { _ = fcntl(master, F_SETFL, masterFlags | O_NONBLOCK) }
        let controlFlags = fcntl(controlRead, F_GETFL)
        if controlFlags >= 0 { _ = fcntl(controlRead, F_SETFL, controlFlags | O_NONBLOCK) }
        let commandFlags = fcntl(commandWrite, F_GETFL)
        if commandFlags >= 0 { _ = fcntl(commandWrite, F_SETFL, commandFlags | O_NONBLOCK) }
        var terminal = termios()
        if tcgetattr(slave, &terminal) == 0 {
            terminal.c_lflag &= ~tcflag_t(ECHO | ECHONL)
            _ = tcsetattr(slave, TCSANOW, &terminal)
        }

        var actions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            [master, slave, controlRead, controlWrite, commandRead, commandWrite,
             controlSpawnFD, commandSpawnFD].forEach { _ = Darwin.close($0) }
            return nil
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        var error = posix_spawn_file_actions_adddup2(&actions, slave, STDIN_FILENO)
        if error == 0 { error = posix_spawn_file_actions_adddup2(&actions, slave, STDOUT_FILENO) }
        if error == 0 { error = posix_spawn_file_actions_adddup2(&actions, slave, STDERR_FILENO) }
        if error == 0 { error = posix_spawn_file_actions_adddup2(&actions, controlSpawnFD, 3) }
        if error == 0 { error = posix_spawn_file_actions_adddup2(&actions, commandSpawnFD, 4) }
        for fd in [master, slave, controlRead, controlWrite, commandRead, commandWrite,
                   controlSpawnFD, commandSpawnFD]
            where error == 0 && fd != 3 && fd != 4 {
            error = posix_spawn_file_actions_addclose(&actions, fd)
        }
        if error == 0 {
            error = directory.path.withCString { posix_spawn_file_actions_addchdir_np(&actions, $0) }
        }

        var attributes: posix_spawnattr_t? = nil
        if error == 0 { error = posix_spawnattr_init(&attributes) }
        guard error == 0 else {
            [master, slave, controlRead, controlWrite, commandRead, commandWrite,
             controlSpawnFD, commandSpawnFD].forEach { _ = Darwin.close($0) }
            return nil
        }
        defer { posix_spawnattr_destroy(&attributes) }
        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        error = posix_spawnattr_setsigmask(&attributes, &signalMask)
        if error == 0 {
            error = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK))
        }
        guard error == 0 else {
            [master, slave, controlRead, controlWrite, commandRead, commandWrite,
             controlSpawnFD, commandSpawnFD].forEach { _ = Darwin.close($0) }
            return nil
        }

        let arguments = [executable, helperArgument, shell]
        let environmentEntries = environment.map { "\($0.key)=\($0.value)" }.sorted()
        var pid: pid_t = 0
        let spawnError = executable.withCString { executablePointer in
            withCStringArray(arguments) { argumentPointers in
                withCStringArray(environmentEntries) { environmentPointers in
                    posix_spawn(&pid, executablePointer, &actions, &attributes, argumentPointers, environmentPointers)
                }
            }
        }
        _ = Darwin.close(slave)
        _ = Darwin.close(controlWrite)
        _ = Darwin.close(controlSpawnFD)
        _ = Darwin.close(commandRead)
        _ = Darwin.close(commandSpawnFD)
        guard spawnError == 0 else {
            _ = Darwin.close(master); _ = Darwin.close(controlRead); _ = Darwin.close(commandWrite)
            return nil
        }
        return SpawnedShell(
            pid: pid,
            masterFD: master,
            controlFD: controlRead,
            commandFD: commandWrite
        )
    }

    private static func withCStringArray<Result>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Result
    ) -> Result {
        let storage = strings.map { strdup($0)! }
        defer { storage.forEach { free($0) } }
        var pointers: [UnsafeMutablePointer<CChar>?] = storage.map(Optional.init)
        pointers.append(nil)
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress) }
    }
}

// Keep migration assertions readable while the legacy one-shot manager remains
// available to older tests and injection points.
func == (lhs: ShellSessionID, rhs: ShellJobID) -> Bool {
    lhs.rawValue == rhs.rawValue
}

func == (lhs: ShellJobID, rhs: ShellSessionID) -> Bool {
    lhs.rawValue == rhs.rawValue
}

/// Compatibility bridge for existing one-shot runner injections.
///
/// It deliberately models a durable logical session but cannot preserve `cd`,
/// exported variables, stdin, or shell-native completion. Production uses the
/// PTY-backed manager; this bridge keeps legacy unit-test seams source-compatible
/// while those tests migrate to `PersistentShellSessionManaging`.
final class LegacyPersistentShellSessionManager: PersistentShellSessionManaging {
    private struct Session {
        let onOutput: (ShellSessionID, String) -> Void
        let onEvent: (ShellSessionID, ShellSessionEvent) -> Void
        var activeJobID: ShellJobID?
        var isClosing = false
    }

    private let jobManager: ShellJobManaging
    private var sessions: [ShellSessionID: Session] = [:]
    private let workingDirectory: String

    init(
        jobManager: ShellJobManaging,
        workingDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) {
        self.jobManager = jobManager
        self.workingDirectory = workingDirectory
    }

    var activeSessionIDs: Set<ShellSessionID> { Set(sessions.keys) }

    @discardableResult
    func startSession(
        id: ShellSessionID,
        onOutput: @escaping (ShellSessionID, String) -> Void,
        onEvent: @escaping (ShellSessionID, ShellSessionEvent) -> Void
    ) -> Bool {
        guard sessions[id] == nil else { return false }
        sessions[id] = Session(onOutput: onOutput, onEvent: onEvent)
        onEvent(id, .ready(cwd: workingDirectory))
        return true
    }

    @discardableResult
    func submitCommand(_ command: String, to id: ShellSessionID) -> Bool {
        guard var session = sessions[id], session.activeJobID == nil, !session.isClosing else {
            return false
        }
        let jobID = ShellJobID(rawValue: id.rawValue)
        session.activeJobID = jobID
        sessions[id] = session

        let accepted = jobManager.runShellCommand(
            command,
            id: jobID,
            onOutput: { [weak self] callbackJobID, output in
                guard let self,
                      let current = self.sessions[id],
                      current.activeJobID == callbackJobID else { return }
                current.onOutput(id, output)
            },
            onCompletion: { [weak self] callbackJobID, result in
                guard let self,
                      var current = self.sessions[id],
                      current.activeJobID == callbackJobID else { return }
                current.activeJobID = nil
                self.sessions[id] = current
                current.onEvent(id, .foregroundFinished(result: result, cwd: self.workingDirectory))
                // The wrapped runner owns a one-shot shell, so its completion
                // also closes this compatibility session. A selected console
                // may still retain the transcript; its next command lazily
                // starts another logical session.
                self.sessions.removeValue(forKey: id)
                current.onEvent(id, .closed(result))
            }
        )

        guard accepted else {
            if var current = sessions[id], current.activeJobID == jobID {
                current.activeJobID = nil
                sessions[id] = current
            }
            return false
        }
        sessions[id]?.onEvent(id, .foregroundStarted(command: command))
        return true
    }

    func sendInputLine(_ input: String, to id: ShellSessionID) -> Bool {
        false
    }

    func interruptForeground(in id: ShellSessionID) {
        guard let jobID = sessions[id]?.activeJobID else { return }
        jobManager.cancel(jobID)
    }

    func requestCompletions(
        input: String,
        cursorUTF16: Int,
        in id: ShellSessionID,
        requestID: ShellCompletionRequestID,
        completion: @escaping (ShellSessionID, ShellCompletionResult) -> Void
    ) {
        completion(
            id,
            ShellCompletionResult(
                requestID: requestID,
                replacementRange: cursorUTF16..<cursorUTF16,
                candidates: []
            )
        )
    }

    func closeSession(_ id: ShellSessionID) {
        guard var session = sessions[id], !session.isClosing else { return }
        session.isClosing = true
        sessions[id] = session
        if let jobID = session.activeJobID {
            jobManager.cancel(jobID)
        } else {
            sessions.removeValue(forKey: id)
            session.onEvent(id, .closed(.success))
        }
    }

    func terminateAllImmediately() {
        jobManager.terminateAllImmediately()
    }
}
