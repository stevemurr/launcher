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

/// Authoritative state of the terminal driver's input echo flag.
///
/// This is distinct from whether Launcher chooses to render its own input. A
/// caller should use a secure editor only while the most recent state is
/// `.disabled`; `nil` from `inputEchoState(for:)` means no terminal state has
/// been observed yet.
enum ShellInputEchoState: Equatable {
    case enabled
    case disabled
}

/// Why a complete foreground input record was rejected before transport.
enum ShellInputRejectionReason: Equatable {
    case sessionNotForeground
    case sessionFinishing
    case containsNUL
    case containsLineBreak
    case canonicalLineTooLong(maximumBytes: Int)
    case nonCanonicalLineTooLong(maximumBytes: Int)
    case inputQueueFull(maximumBytes: Int)
    case terminalStateUnavailable
    case transportFailed
}

/// Typed result for a foreground input submission.
enum ShellInputSubmissionResult: Equatable {
    case accepted
    case rejected(ShellInputRejectionReason)
}

/// State changes emitted by a persistent shell's private control channel.
enum ShellSessionEvent: Equatable {
    case ready(cwd: String)
    case foregroundStarted(command: String)
    case foregroundFinished(result: ScriptRunResult, cwd: String)
    /// Emitted whenever an authoritative `tcgetattr` observation differs from
    /// the last published state, including changes made by a foreground child.
    case inputEchoStateChanged(ShellInputEchoState)
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

    /// Sends one newline-terminated foreground input record with a typed result.
    /// Rejections are atomic: no portion of the record is written. Acceptance
    /// transfers the complete record to the manager's nonblocking write queue;
    /// a later transport failure closes the session with an actionable event.
    @discardableResult
    func submitInputLine(
        _ input: String,
        to id: ShellSessionID
    ) -> ShellInputSubmissionResult

    /// Returns the most recently observed terminal-driver ECHO state. `nil`
    /// means that no authoritative observation exists for this active session.
    func inputEchoState(for id: ShellSessionID) -> ShellInputEchoState?

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

extension PersistentShellSessionManaging {
    /// Compatibility behavior for test doubles and legacy adapters that only
    /// implement the original Boolean API. Production overrides this method to
    /// provide precise rejection reasons.
    func submitInputLine(
        _ input: String,
        to id: ShellSessionID
    ) -> ShellInputSubmissionResult {
        sendInputLine(input, to: id)
            ? .accepted
            : .rejected(.sessionNotForeground)
    }

    func inputEchoState(for id: ShellSessionID) -> ShellInputEchoState? { nil }
}

/// PTY-backed implementation used by the application.
///
/// `openpty` is safe in a multithreaded process; `forkpty` is not.  The parent
/// therefore opens the terminal and uses `posix_spawn` to start a tiny mode of
/// the Launcher executable.  That pristine helper can safely create a session,
/// acquire the terminal, and `execve` the user's login shell.
final class ProcessPersistentShellSessionManager: PersistentShellSessionManaging {
    private struct PendingInputRecord {
        let data: Data
        var offset = 0
    }

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
        var inputWriteSource: DispatchSourceWrite?
        var inputWriteSourceIsSuspended = true
        var controlSource: DispatchSourceRead?
        var processSource: DispatchSourceProcess?
        var closeRequested = false
        var closedResultOverride: ScriptRunResult?
        var interruptRequested = false
        var interruptSignalPending = false
        var interruptPollGeneration = 0
        var interruptProbePending = false
        var completionProbePending = false
        var pendingForegroundResult: ScriptRunResult?
        var commandBaselineDescendants: Set<pid_t> = []
        var currentCommand: String?
        var inputEchoState: ShellInputEchoState?
        var echoPollGeneration = 0
        var pendingInputRecords: [PendingInputRecord] = []
        var pendingInputByteCount = 0

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
    private let controlProbeTimeout: TimeInterval
    private let onTerminalEchoObservation: (() -> Void)?
    private var sessions: [ShellSessionID: Session] = [:]
    private static let outputFlushInterval: DispatchTimeInterval = .milliseconds(50)
    private static let maximumPendingOutputCharacters = 100_000
    private static let fastEchoPollCount = 20
    private static let moderateEchoPollCount = 10
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
    /// Complete canonical records must fit comfortably below Darwin's tty line
    /// queue. The public payload limit is one byte smaller because Launcher
    /// appends the terminating carriage return.
    static let maximumTerminalLineBytes = 512
    static let maximumCanonicalInputBytes = maximumTerminalLineBytes - 1
    /// Noncanonical readers consume bytes as they arrive and are not constrained
    /// by the canonical line queue. Retain a generous finite transport bound.
    static let maximumNonCanonicalInputBytes = 64 * 1_024
    private static let maximumQueuedInputBytes = 256 * 1_024
    static let maximumCommandBytes = 64 * 1_024

    init(
        // The private wrapper intentionally targets zsh. Selecting an arbitrary
        // `$SHELL` here would make fish/tcsh installations start a dead session.
        shellPath: String = "/bin/zsh",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        helperExecutablePath: String? = nil,
        startupTimeout: TimeInterval = 8,
        controlProbeTimeout: TimeInterval = 8,
        onTerminalEchoObservation: (() -> Void)? = nil
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
        self.controlProbeTimeout = max(0.1, controlProbeTimeout)
        self.onTerminalEchoObservation = onTerminalEchoObservation
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
            session.interruptProbePending = false
            session.completionProbePending = false
            session.pendingForegroundResult = nil
            session.interruptPollGeneration &+= 1
            session.currentCommand = command
            session.commandBaselineDescendants = Set(Self.descendantPIDs(of: session.pid))
            // The wrapper is an anonymous function, injected with terminal echo
            // suppressed. It cannot be removed or redefined by a previous user
            // command. Potentially secret/large user text travels only on FD4.
            guard writeInternalScript(Self.commandWrapperScript, to: session),
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
        submitInputLine(input, to: id) == .accepted
    }

    @discardableResult
    func submitInputLine(
        _ input: String,
        to id: ShellSessionID
    ) -> ShellInputSubmissionResult {
        queue.sync {
            guard let session = sessions[id], session.phase == .foreground else {
                return .rejected(.sessionNotForeground)
            }
            guard session.pendingForegroundResult == nil,
                  !session.completionProbePending,
                  !session.interruptProbePending else {
                return .rejected(.sessionFinishing)
            }
            guard !input.contains("\0") else { return .rejected(.containsNUL) }
            guard !input.contains("\n"), !input.contains("\r") else {
                return .rejected(.containsLineBreak)
            }

            let byteCount = input.utf8.count
            if byteCount > Self.maximumCanonicalInputBytes {
                guard let attributes = Self.terminalAttributes(for: session.masterFD) else {
                    return .rejected(.terminalStateUnavailable)
                }
                if attributes.c_lflag & tcflag_t(ICANON) != 0 {
                    return .rejected(.canonicalLineTooLong(
                        maximumBytes: Self.maximumCanonicalInputBytes
                    ))
                }
                guard byteCount <= Self.maximumNonCanonicalInputBytes else {
                    return .rejected(.nonCanonicalLineTooLong(
                        maximumBytes: Self.maximumNonCanonicalInputBytes
                    ))
                }
            }

            var record = Data(input.utf8)
            record.append(0x0D)
            guard session.pendingInputByteCount + record.count <= Self.maximumQueuedInputBytes else {
                return .rejected(.inputQueueFull(maximumBytes: Self.maximumQueuedInputBytes))
            }
            session.pendingInputRecords.append(PendingInputRecord(data: record))
            session.pendingInputByteCount += record.count
            drainPendingInput(for: session)
            // Acceptance means the complete record is owned by the manager.
            // A later transport failure closes the session; it is never
            // reported as a rejection after a prefix may have been written.
            return .accepted
        }
    }

    func inputEchoState(for id: ShellSessionID) -> ShellInputEchoState? {
        queue.sync { sessions[id]?.inputEchoState }
    }

    func interruptForeground(in id: ShellSessionID) {
        queue.async { [self] in
            guard let session = self.sessions[id], session.phase == .foreground else { return }
            guard !session.interruptSignalPending else { return }
            self.discardPendingInput(for: session)
            session.interruptRequested = true
            session.interruptSignalPending = true
            session.interruptPollGeneration &+= 1
            let generation = session.interruptPollGeneration
            self.queue.asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self, weak session] in
                guard let self, let session, self.sessions[session.id] === session else { return }
                session.interruptSignalPending = false
            }
            // S is emitted just before eval. Give zsh a short interval to place
            // the actual command in the foreground so SIGINT cannot hit a
            // transient wrapper and miss the eventual child.
            self.queue.asyncAfter(deadline: .now() + .milliseconds(75)) { [weak self, weak session] in
                guard let self, let session,
                      self.sessions[session.id] === session,
                      session.phase == .foreground,
                      session.interruptRequested,
                      session.interruptPollGeneration == generation else { return }
                self.resolveAndSignalInterrupt(
                    session,
                    attemptsRemaining: 40,
                    generation: generation
                )
            }
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
            self.discardPendingInput(for: session)
            session.closeRequested = true
            session.phase = .closing
            let foregroundGroup = tcgetpgrp(session.masterFD)
            if foregroundGroup > 0, foregroundGroup != session.pid {
                _ = kill(-foregroundGroup, SIGTERM)
            } else if foregroundGroup == session.pid {
                _ = self.writeInternalScript("exit\n", to: session)
            }
            self.scheduleEscalation(for: session)
        }
    }

    func terminateAllImmediately() {
        queue.sync {
            for session in sessions.values {
                discardPendingInput(for: session)
                cancelInputWriteSource(for: session)
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

    /// Every foreground command receives a fresh anonymous wrapper. No mutable
    /// function name or prompt-hook entry is part of the control protocol, so a
    /// user command cannot wedge future submissions with `unfunction`, alias,
    /// or `precmd_functions` mutations.
    private static let commandWrapperScript = """
    () {
      \\enable builtin 2>/dev/null
      \\builtin local __launcher_private_b64 __launcher_private_command
      \\builtin local __launcher_private_status='' __launcher_private_cwd __launcher_private_path __launcher_private_home
      \\builtin local __launcher_private_shell_commands
      IFS= \\builtin read -r __launcher_private_b64 <&4 || \\builtin return 125
      __launcher_private_command="$(/usr/bin/printf '%s' "$__launcher_private_b64" | /usr/bin/base64 -D)"
      /usr/bin/printf 'S\n' >&3
      {
        \\builtin eval "$__launcher_private_command" 3>&- 4>&-
        __launcher_private_status=$?
      } always {
        \\enable builtin 2>/dev/null
        [[ -n "$__launcher_private_status" ]] || __launcher_private_status=130
        __launcher_private_cwd="$(/usr/bin/printf '%s' "$PWD" | /usr/bin/base64)"
        __launcher_private_path="$(/usr/bin/printf '%s' "$PATH" | /usr/bin/base64)"
        __launcher_private_home="$(/usr/bin/printf '%s' "$HOME" | /usr/bin/base64)"
        __launcher_private_shell_commands="$(
          /usr/bin/printf '%s\\0' "${(@k)aliases}" "${(@k)functions}" | /usr/bin/base64
        )"
        /usr/bin/printf 'F\t%s\t%s\t%s\t%s\t%s\n' \
          "$__launcher_private_status" "$__launcher_private_cwd" \
          "$__launcher_private_path" "$__launcher_private_home" \
          "$__launcher_private_shell_commands" >&3
      }
    }
    """ + "\n"

    /// Used only after SIGINT has returned terminal ownership to the shell
    /// without an F frame. The private FD4 token lets the manager restore the
    /// user's ECHO setting before this anonymous probe begins executing.
    private static let interruptProbeScript = """
    () {
      \\enable builtin 2>/dev/null
      \\builtin local __launcher_private_probe __launcher_private_cwd __launcher_private_path __launcher_private_home
      \\builtin local __launcher_private_shell_commands
      IFS= \\builtin read -r __launcher_private_probe <&4 || \\builtin return 125
      __launcher_private_cwd="$(/usr/bin/printf '%s' "$PWD" | /usr/bin/base64)"
      __launcher_private_path="$(/usr/bin/printf '%s' "$PATH" | /usr/bin/base64)"
      __launcher_private_home="$(/usr/bin/printf '%s' "$HOME" | /usr/bin/base64)"
      __launcher_private_shell_commands="$(
        /usr/bin/printf '%s\\0' "${(@k)aliases}" "${(@k)functions}" | /usr/bin/base64
      )"
      /usr/bin/printf 'I\t%s\t%s\t%s\t%s\n' \
        "$__launcher_private_cwd" "$__launcher_private_path" \
        "$__launcher_private_home" "$__launcher_private_shell_commands" >&3
    }
    """ + "\n"

    /// Runs at the next shell prompt after an ordinary F frame. Delaying the
    /// public completion event until this probe executes prevents callers from
    /// submitting terminal input while zsh is still unwinding the wrapper or
    /// flushing SIGINT input state.
    private static let completionProbeScript = """
    () {
      \\enable builtin 2>/dev/null
      \\builtin local __launcher_private_probe __launcher_private_cwd __launcher_private_path __launcher_private_home
      \\builtin local __launcher_private_shell_commands
      IFS= \\builtin read -r __launcher_private_probe <&4 || \\builtin return 125
      __launcher_private_cwd="$(/usr/bin/printf '%s' "$PWD" | /usr/bin/base64)"
      __launcher_private_path="$(/usr/bin/printf '%s' "$PATH" | /usr/bin/base64)"
      __launcher_private_home="$(/usr/bin/printf '%s' "$HOME" | /usr/bin/base64)"
      __launcher_private_shell_commands="$(
        /usr/bin/printf '%s\\0' "${(@k)aliases}" "${(@k)functions}" | /usr/bin/base64
      )"
      /usr/bin/printf 'Q\t%s\t%s\t%s\t%s\n' \
        "$__launcher_private_cwd" "$__launcher_private_path" \
        "$__launcher_private_home" "$__launcher_private_shell_commands" >&3
    }
    """ + "\n"

    private func installSources(for session: Session) {
        let output = DispatchSource.makeReadSource(fileDescriptor: session.masterFD, queue: queue)
        output.setEventHandler { [weak self, weak session] in
            guard let self, let session, self.sessions[session.id] === session else { return }
            self.consumeOutput(from: session)
        }
        output.setCancelHandler { _ = Darwin.close(session.masterFD) }
        session.outputSource = output

        // The source starts suspended and is resumed only when a nonblocking
        // PTY write reaches EAGAIN. This lets accepted raw records drain later
        // without blocking the caller or ever classifying a partial write as a
        // rejected submission.
        let input = DispatchSource.makeWriteSource(fileDescriptor: session.masterFD, queue: queue)
        input.setEventHandler { [weak self, weak session] in
            guard let self, let session, self.sessions[session.id] === session else { return }
            self.drainPendingInput(for: session)
        }
        session.inputWriteSource = input

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

    private func drainPendingInput(for session: Session) {
        while !session.pendingInputRecords.isEmpty {
            var record = session.pendingInputRecords[0]
            let count = record.data.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return Darwin.write(
                    session.masterFD,
                    base.advanced(by: record.offset),
                    buffer.count - record.offset
                )
            }
            if count > 0 {
                record.offset += count
                session.pendingInputByteCount -= count
                if record.offset == record.data.count {
                    session.pendingInputRecords.removeFirst()
                } else {
                    session.pendingInputRecords[0] = record
                }
                continue
            }
            if count == -1, errno == EINTR { continue }
            if count == -1, errno == EAGAIN || errno == EWOULDBLOCK {
                resumeInputWriteSourceIfNeeded(for: session)
                return
            }

            let message = count == -1
                ? String(cString: strerror(errno))
                : "PTY accepted no input bytes"
            discardPendingInput(for: session)
            failControlProtocol(
                for: session,
                message: "Shell input transport failed: \(message)"
            )
            return
        }
        suspendInputWriteSourceIfNeeded(for: session)
    }

    private func resumeInputWriteSourceIfNeeded(for session: Session) {
        guard session.inputWriteSourceIsSuspended,
              let source = session.inputWriteSource else { return }
        session.inputWriteSourceIsSuspended = false
        source.resume()
    }

    private func suspendInputWriteSourceIfNeeded(for session: Session) {
        guard !session.inputWriteSourceIsSuspended,
              let source = session.inputWriteSource else { return }
        session.inputWriteSourceIsSuspended = true
        source.suspend()
    }

    private func discardPendingInput(for session: Session) {
        session.pendingInputRecords.removeAll(keepingCapacity: false)
        session.pendingInputByteCount = 0
        suspendInputWriteSourceIfNeeded(for: session)
    }

    private func cancelInputWriteSource(for session: Session) {
        guard let source = session.inputWriteSource else { return }
        if session.inputWriteSourceIsSuspended { source.resume() }
        session.inputWriteSourceIsSuspended = false
        source.cancel()
        session.inputWriteSource = nil
    }

    private func sendInitialization(to session: Session) {
        // The startup command is constant and contains no user data or secrets.
        // It establishes only presentation state and emits one initial frame;
        // later protocol operations use fresh anonymous wrappers.
        let script = """
        unsetopt PROMPT_CR PROMPT_SP ZLE 2>/dev/null
        PS1=''; PS2=''
        () {
          \\enable builtin 2>/dev/null
          \\builtin local __launcher_private_cwd __launcher_private_path __launcher_private_home
          \\builtin local __launcher_private_shell_commands
          __launcher_private_cwd="$(/usr/bin/printf '%s' "$PWD" | /usr/bin/base64)"
          __launcher_private_path="$(/usr/bin/printf '%s' "$PATH" | /usr/bin/base64)"
          __launcher_private_home="$(/usr/bin/printf '%s' "$HOME" | /usr/bin/base64)"
          __launcher_private_shell_commands="$(
            /usr/bin/printf '%s\\0' "${(@k)aliases}" "${(@k)functions}" | /usr/bin/base64
          )"
          /usr/bin/printf 'R\\t%s\\t%s\\t%s\\t%s\\n' \
            "$__launcher_private_cwd" "$__launcher_private_path" \
            "$__launcher_private_home" "$__launcher_private_shell_commands" >&3
        }
        """ + "\n"
        guard writeInternalScript(script, to: session) else {
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
        var didReadOutput = false
        while iterations < 16 {
            iterations += 1
            let count = Darwin.read(session.masterFD, &bytes, bytes.count)
            if count > 0 {
                didReadOutput = true
                let raw = session.decoder.decode(bytes[..<count])
                let clean = session.sanitizer.sanitize(raw)
                if session.phase != .starting { enqueueOutput(clean, for: session) }
            } else if count == -1, errno == EINTR {
                continue
            } else {
                break
            }
        }
        if didReadOutput, session.phase == .foreground {
            // Output commonly accompanies a password/read prompt. Observe ECHO
            // immediately and restart a short fast-polling burst around it.
            refreshInputEchoState(for: session)
            beginForegroundEchoPolling(for: session)
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
            if fields.indices.contains(3), let home = decode64(fields[3]) {
                session.home = home
            }
            if fields.indices.contains(4) {
                updateShellCommandNames(from: fields[4], for: session)
            }
            // The shell writes its startup/banner/initialization echo before R,
            // but the PTY and control pipe have independent dispatch sources.
            // Drain that already-produced terminal data while still starting.
            consumeOutput(from: session)
            _ = session.sanitizer.sanitize(session.decoder.finish())
            _ = session.sanitizer.finish()
            session.cwd = cwd
            session.path = path
            if session.phase == .starting {
                session.phase = .ready
                emit(.ready(cwd: cwd), for: session)
                refreshInputEchoState(for: session)
            }

        case "S":
            let command = session.currentCommand ?? ""
            emit(.foregroundStarted(command: command), for: session)
            refreshInputEchoState(for: session)
            beginForegroundEchoPolling(for: session)

        case "F" where fields.count >= 4:
            guard session.phase == .foreground else { return }
            guard let status = Int32(fields[1]),
                  let cwd = decode64(fields[2]),
                  let path = decode64(fields[3]) else { return }
            if fields.indices.contains(4), let home = decode64(fields[4]) {
                session.home = home
            }
            if fields.indices.contains(5) {
                updateShellCommandNames(from: fields[5], for: session)
            }
            discardPendingInput(for: session)
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
            session.pendingForegroundResult = result
            session.interruptPollGeneration &+= 1
            session.interruptSignalPending = false
            refreshInputEchoState(for: session)
            if !session.interruptProbePending {
                beginCompletionProbe(for: session)
            }

        case "I" where fields.count >= 3:
            guard session.phase == .foreground,
                  session.interruptRequested,
                  session.interruptProbePending,
                  let cwd = decode64(fields[1]),
                  let path = decode64(fields[2]) else { return }
            if fields.indices.contains(3), let home = decode64(fields[3]) {
                session.home = home
            }
            if fields.indices.contains(4) {
                updateShellCommandNames(from: fields[4], for: session)
            }
            completeForeground(
                session,
                result: session.pendingForegroundResult ?? .cancelled,
                cwd: cwd,
                path: path
            )

        case "Q" where fields.count >= 3:
            guard session.phase == .foreground,
                  session.completionProbePending,
                  let result = session.pendingForegroundResult,
                  let cwd = decode64(fields[1]),
                  let path = decode64(fields[2]) else { return }
            if fields.indices.contains(3), let home = decode64(fields[3]) {
                session.home = home
            }
            if fields.indices.contains(4) {
                updateShellCommandNames(from: fields[4], for: session)
            }
            completeForeground(session, result: result, cwd: cwd, path: path)

        default:
            break
        }
    }

    private func beginCompletionProbe(for session: Session) {
        guard !session.completionProbePending else { return }
        guard writeInternalScript(Self.completionProbeScript, to: session),
              write("Q\n", to: session.commandFD) else {
            failControlProtocol(
                for: session,
                message: "Shell did not accept the command-completion state probe."
            )
            return
        }
        session.completionProbePending = true
        let generation = session.interruptPollGeneration
        queue.asyncAfter(deadline: .now() + controlProbeTimeout) { [weak self, weak session] in
            guard let self, let session,
                  self.sessions[session.id] === session,
                  session.phase == .foreground,
                  session.completionProbePending,
                  session.interruptPollGeneration == generation else { return }
            self.failControlProtocol(
                for: session,
                message: "Shell state probe timed out after command completion."
            )
        }
    }

    private func completeForeground(
        _ session: Session,
        result: ScriptRunResult,
        cwd: String,
        path: String
    ) {
        discardPendingInput(for: session)
        session.cwd = cwd
        session.path = path
        consumeOutput(from: session)
        enqueueOutput(session.sanitizer.sanitize(session.decoder.finish()), for: session)
        enqueueOutput(session.sanitizer.finish(), for: session)
        flushOutput(for: session)
        session.interruptRequested = false
        session.interruptSignalPending = false
        session.interruptProbePending = false
        session.completionProbePending = false
        session.pendingForegroundResult = nil
        session.interruptPollGeneration &+= 1
        session.currentCommand = nil
        session.phase = session.closeRequested ? .closing : .ready
        refreshInputEchoState(for: session)
        emit(.foregroundFinished(result: result, cwd: cwd), for: session)
        if session.closeRequested {
            _ = writeInternalScript("exit\n", to: session)
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
        discardPendingInput(for: session)
        sessions.removeValue(forKey: session.id)
        cancelInputWriteSource(for: session)
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

    /// Writes manager-owned shell syntax without allowing it to appear as user
    /// terminal output. The prior terminal settings are restored before a
    /// command token is sent on FD4, so foreground programs observe the user's
    /// actual ECHO mode rather than the transient injection mode.
    private func writeInternalScript(_ script: String, to session: Session) -> Bool {
        guard var original = Self.terminalAttributes(for: session.masterFD) else { return false }
        var suppressed = original
        suppressed.c_lflag &= ~tcflag_t(ECHO | ECHONL)
        guard tcsetattr(session.masterFD, TCSANOW, &suppressed) == 0 else { return false }
        let didWrite = write(script, to: session.masterFD)
        let didRestore = tcsetattr(session.masterFD, TCSANOW, &original) == 0
        return didWrite && didRestore
    }

    private static func terminalAttributes(for descriptor: Int32) -> termios? {
        var attributes = termios()
        return tcgetattr(descriptor, &attributes) == 0 ? attributes : nil
    }

    private func refreshInputEchoState(for session: Session) {
        onTerminalEchoObservation?()
        guard let attributes = Self.terminalAttributes(for: session.masterFD) else { return }
        let state: ShellInputEchoState = attributes.c_lflag & tcflag_t(ECHO) != 0
            ? .enabled
            : .disabled
        guard state != session.inputEchoState else { return }
        session.inputEchoState = state
        emit(.inputEchoStateChanged(state), for: session)
    }

    private func beginForegroundEchoPolling(for session: Session) {
        session.echoPollGeneration &+= 1
        pollForegroundEcho(for: session, generation: session.echoPollGeneration, attempt: 0)
    }

    private func pollForegroundEcho(for session: Session, generation: Int, attempt: Int) {
        let interval: DispatchTimeInterval
        if attempt < Self.fastEchoPollCount {
            interval = .milliseconds(25)
        } else if attempt < Self.fastEchoPollCount + Self.moderateEchoPollCount {
            interval = .milliseconds(100)
        } else {
            // Persisted foreground jobs may live for hours. Retain eventual
            // observation without paying forty tcgetattr wakeups per second.
            interval = .seconds(1)
        }
        queue.asyncAfter(deadline: .now() + interval) { [weak self, weak session] in
            guard let self, let session,
                  self.sessions[session.id] === session,
                  session.phase == .foreground,
                  session.echoPollGeneration == generation else { return }
            self.refreshInputEchoState(for: session)
            self.pollForegroundEcho(
                for: session,
                generation: generation,
                attempt: attempt + 1
            )
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

    /// Alias and function names are emitted as a base64-encoded NUL-separated
    /// byte sequence. They are treated only as completion data: neither names
    /// nor the user's draft are evaluated to discover live shell commands.
    private func updateShellCommandNames(from encoded: String, for session: Session) {
        guard let data = Data(base64Encoded: encoded) else { return }
        let liveNames = data.split(separator: 0).compactMap { bytes in
            String(data: Data(bytes), encoding: .utf8)
        }
        session.shellCommandNames = Self.zshBuiltinCommandNames.union(liveNames)
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
        var result: [pid_t] = []
        var visited: Set<pid_t> = [parent]

        func visit(_ current: pid_t) {
            for child in directChildPIDs(of: current)
                where child > 0 && visited.insert(child).inserted {
                result.append(child)
                visit(child)
            }
        }

        visit(parent)
        return result
    }

    /// `proc_listchildpids` returns a number of PIDs, not a byte count. Grow
    /// until the returned count no longer fills the supplied PID capacity so a
    /// shell with hundreds of background job-control groups is fully covered.
    private static func directChildPIDs(of parent: pid_t) -> [pid_t] {
        var capacity = 64
        let maximumCapacity = 1 << 20

        while true {
            var children = [pid_t](repeating: 0, count: capacity)
            let count = children.withUnsafeMutableBytes { buffer in
                proc_listchildpids(parent, buffer.baseAddress, Int32(buffer.count))
            }
            guard count > 0 else { return [] }
            let pidCount = min(Int(count), capacity)
            if pidCount < capacity || capacity >= maximumCapacity {
                return Array(children.prefix(pidCount).filter { $0 > 0 })
            }
            capacity = min(capacity * 2, maximumCapacity)
        }
    }

    private func pollForShellReadyAfterInterrupt(
        _ session: Session,
        generation: Int,
        shellOwnershipChecks: Int
    ) {
        queue.asyncAfter(deadline: .now() + .milliseconds(25)) { [weak self, weak session] in
            guard let self, let session,
                  self.sessions[session.id] === session,
                  session.phase == .foreground,
                  session.interruptRequested,
                  session.interruptPollGeneration == generation else { return }
            let foregroundGroup = tcgetpgrp(session.masterFD)
            if foregroundGroup == session.pid {
                if shellOwnershipChecks < 4 {
                    self.pollForShellReadyAfterInterrupt(
                        session,
                        generation: generation,
                        shellOwnershipChecks: shellOwnershipChecks + 1
                    )
                    return
                }
                // Terminal ownership proves the foreground program returned,
                // but cached cwd is not authoritative. Ask the live shell over
                // the private control channel and complete only after I arrives.
                guard !session.interruptProbePending else { return }
                guard self.writeInternalScript(Self.interruptProbeScript, to: session),
                      self.write("P\n", to: session.commandFD) else {
                    self.failControlProtocol(
                        for: session,
                        message: "Shell did not accept the post-interrupt state probe."
                    )
                    return
                }
                session.interruptProbePending = true
                self.scheduleInterruptProbeTimeout(for: session, generation: generation)
            } else {
                // A signal-handling Claude/TUI retains its own foreground group.
                // Continue observing without injecting recovery input into it.
                self.pollForShellReadyAfterInterrupt(
                    session,
                    generation: generation,
                    shellOwnershipChecks: 0
                )
            }
        }
    }

    private func scheduleInterruptProbeTimeout(for session: Session, generation: Int) {
        queue.asyncAfter(deadline: .now() + controlProbeTimeout) { [weak self, weak session] in
            guard let self, let session,
                  self.sessions[session.id] === session,
                  session.phase == .foreground,
                  session.interruptRequested,
                  session.interruptProbePending,
                  session.interruptPollGeneration == generation else { return }
            self.failControlProtocol(
                for: session,
                message: "Shell state probe timed out after interrupt."
            )
        }
    }

    private func failControlProtocol(for session: Session, message: String) {
        guard sessions[session.id] === session else { return }
        discardPendingInput(for: session)
        cancelInputWriteSource(for: session)
        session.closedResultOverride = .failedToStart(message)
        session.closeRequested = true
        session.phase = .closing
        session.interruptRequested = false
        session.interruptSignalPending = false
        session.interruptProbePending = false
        session.completionProbePending = false
        session.pendingForegroundResult = nil
        session.interruptPollGeneration &+= 1
        Self.signalForeground(of: session, signal: SIGTERM)
        Self.signalDescendants(of: session.pid, signal: SIGTERM)
        _ = kill(-session.pid, SIGTERM)
        _ = kill(session.pid, SIGTERM)
        scheduleEscalation(for: session)
    }

    private func resolveAndSignalInterrupt(
        _ session: Session,
        attemptsRemaining: Int,
        generation: Int
    ) {
        queue.asyncAfter(deadline: .now() + .milliseconds(25)) { [weak self, weak session] in
            guard let self, let session,
                  self.sessions[session.id] === session,
                  session.phase == .foreground,
                  session.interruptRequested,
                  session.interruptPollGeneration == generation else { return }
            let group = Self.foregroundGroup(of: session)
            if group > 0, group != session.pid {
                let groupResult = kill(-group, SIGINT)
                let directResult = groupResult == 0 ? 0 : kill(group, SIGINT)
                if groupResult == 0 || directResult == 0 {
                    session.interruptSignalPending = false
                    self.pollForShellReadyAfterInterrupt(
                        session,
                        generation: generation,
                        shellOwnershipChecks: 0
                    )
                    return
                }
            }

            let newDescendants = Set(Self.descendantPIDs(of: session.pid))
                .subtracting(session.commandBaselineDescendants)
            var signalledChild = false
            for child in newDescendants where kill(child, SIGINT) == 0 { signalledChild = true }
            if signalledChild {
                session.interruptSignalPending = false
                self.pollForShellReadyAfterInterrupt(
                    session,
                    generation: generation,
                    shellOwnershipChecks: 0
                )
            } else if attemptsRemaining > 37 {
                // Skip transient decoder/command-substitution children created
                // between the S frame and the actual foreground command.
                self.resolveAndSignalInterrupt(
                    session,
                    attemptsRemaining: attemptsRemaining - 1,
                    generation: generation
                )
            } else {
                _ = kill(-session.pid, SIGINT)
                session.interruptSignalPending = false
                self.pollForShellReadyAfterInterrupt(
                    session,
                    generation: generation,
                    shellOwnershipChecks: 0
                )
            }
        }
    }

    // MARK: Completion

    private struct CompletionTokenContext {
        let start: Int
        let end: Int
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

        // Candidate filtering uses only the prefix through the caret, but an
        // accepted candidate replaces the complete shell word. Continue the
        // lexical scan so a mid-token completion never leaves the old suffix
        // attached to the inserted candidate.
        var end = cursor
        var trailingQuote = quote
        var trailingEscape = escaped
        while end < utf16.count {
            let value = utf16[end]
            if trailingEscape {
                trailingEscape = false
                end += 1
                continue
            }
            if value == 0x5C, trailingQuote != 0x27 {
                trailingEscape = true
                end += 1
                continue
            }
            if let activeQuote = trailingQuote {
                if value == activeQuote { trailingQuote = nil }
                end += 1
                continue
            }
            if value == 0x27 || value == 0x22 {
                trailingQuote = value
                end += 1
                continue
            }
            if value == 0x20 || value == 0x09 || value == 0x0A || value == 0x0D
                || value == 0x3B || value == 0x7C || value == 0x26
                || value == 0x28 || value == 0x29 || value == 0x3C || value == 0x3E {
                break
            }
            end += 1
        }

        let token = String(decoding: utf16[start..<cursor], as: UTF16.self)
        let openingQuote = token.first.flatMap { $0 == "'" || $0 == "\"" ? $0 : nil }
        let currentIsAssignment = expectsCommand && isAssignmentWord(utf16[start..<cursor])
        return CompletionTokenContext(
            start: start,
            end: end,
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
            replacementRange: start..<context.end,
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
