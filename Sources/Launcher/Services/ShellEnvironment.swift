import Darwin
import Foundation

/// The environment a script would see if the user ran it from Terminal.
///
/// A GUI app launched from Finder, a login item, or Xcode inherits launchd's
/// bare environment: `PATH` is `/usr/bin:/bin:/usr/sbin:/sbin` and nothing from
/// the user's shell startup files is present. Scripts written and tested in a
/// terminal then die with "command not found" the moment they run from the
/// launcher, because Homebrew, mise/nvm/pyenv shims, and every `export` in
/// `.zshrc`/`.zprofile` are missing. We recover the real thing by asking the
/// login shell to dump its own environment.
///
/// The dump is captured once and cached for the lifetime of the process, so
/// edits to shell startup files take effect the next time the launcher starts.
final class ShellEnvironment {
    static let shared = ShellEnvironment()

    private typealias Resolution = ([String: String]) -> Void

    private enum ResolutionState {
        case unresolved
        case resolving([Resolution])
        case ready([String: String])
    }

    /// Markers bracket the dump so shell startup noise printed by rc files
    /// (banners, version managers, `echo`s) can't be mistaken for variables.
    private static let beginMarker = "__LAUNCHER_ENV_BEGIN__"
    private static let endMarker = "__LAUNCHER_ENV_END__"
    private static let dumpCommand =
        "printf '%s' '\(beginMarker)'; /usr/bin/env -0; printf '%s' '\(endMarker)'"

    /// Long enough for a heavyweight `.zshrc` (oh-my-zsh, version managers) on
    /// a cold start, short enough that a pathological one can't wedge the app.
    private static let captureTimeout: TimeInterval = 5
    /// Both interactive and plain-login attempts share one monotonic budget;
    /// a pathological startup file must not make first-run preparation wait
    /// for two full timeout windows.
    private static let totalCaptureTimeout: TimeInterval = 5
    /// Shell startup files are user-controlled. Bound banners and malformed
    /// dumps so a noisy or infinite producer cannot grow memory until timeout.
    private static let maximumCaptureBytes = 1_048_576

    /// Variables that describe the *capturing* shell rather than the user's
    /// configuration. `PWD`/`OLDPWD` would contradict the working directory we
    /// set for the script, and `_` is the shell's own last-argument scratch.
    private static let transientVariables: Set<String> = ["PWD", "OLDPWD", "_"]

    private let lock = NSLock()
    private var state: ResolutionState = .unresolved
    private let capture: () -> [String: String]?
    private let captureQueue = DispatchQueue(label: "launcher.shellEnvironment.capture", qos: .utility)

    /// - Parameter capture: Overridable for tests; returns nil when the login
    ///   shell can't be interrogated, which falls back to the app's own
    ///   environment (the pre-existing behavior).
    init(capture: @escaping () -> [String: String]? = { ShellEnvironment.captureLoginShellEnvironment() }) {
        self.capture = capture
    }

    /// The environment to hand to spawned scripts. Synchronous callers wait for
    /// an in-flight resolution, but the lock is never held while the login shell
    /// is interrogated. Script execution uses `resolve(_:)` instead so a cold or
    /// pathological shell startup can never block the main thread.
    func resolved() -> [String: String] {
        let semaphore = DispatchSemaphore(value: 0)
        var result: [String: String] = [:]
        resolve {
            result = $0
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    /// Resolves once and coalesces all concurrent callers. The completion runs
    /// on the private capture queue for a cold resolution and inline when the
    /// cached value is already available; callers that care about their queue
    /// should hop explicitly. No caller executes shell startup work itself.
    func resolve(_ completion: @escaping ([String: String]) -> Void) {
        lock.lock()
        switch state {
        case let .ready(environment):
            lock.unlock()
            completion(environment)
        case var .resolving(completions):
            completions.append(completion)
            state = .resolving(completions)
            lock.unlock()
        case .unresolved:
            state = .resolving([completion])
            lock.unlock()
            captureQueue.async { [self] in
                let environment = buildEnvironment(captured: capture())

                lock.lock()
                guard case let .resolving(completions) = state else {
                    lock.unlock()
                    return
                }
                state = .ready(environment)
                lock.unlock()

                completions.forEach { $0(environment) }
            }
        }
    }

    private func buildEnvironment(captured: [String: String]?) -> [String: String] {
        // Start from our own environment so launchd-provided essentials
        // (HOME, TMPDIR, __CF_USER_TEXT_ENCODING…) survive even if the shell
        // dump is unusable, then let the shell's values win where they differ.
        var environment = ProcessInfo.processInfo.environment
        if let captured {
            for (key, value) in captured where !Self.transientVariables.contains(key) {
                environment[key] = value
            }
        }
        Self.transientVariables.forEach { environment.removeValue(forKey: $0) }
        return environment
    }

    /// Resolves the environment in the background so the first script run
    /// doesn't wait on a cold shell startup.
    func prewarm() {
        resolve { _ in }
    }

    // MARK: - Capture

    /// The user's login shell, from `SHELL` when the launching context set one
    /// and the account record otherwise. Nil when the account has no usable
    /// shell (`/usr/bin/false`, `/sbin/nologin`).
    static func loginShellPath() -> String? {
        var candidates: [String] = []
        if let shell = ProcessInfo.processInfo.environment["SHELL"] { candidates.append(shell) }
        if let record = getpwuid(getuid())?.pointee.pw_shell {
            candidates.append(String(cString: record))
        }
        candidates.append("/bin/zsh")

        return candidates.first { path in
            !path.isEmpty
                && !path.hasSuffix("/false")
                && !path.hasSuffix("/nologin")
                && FileManager.default.isExecutableFile(atPath: path)
        }
    }

    static func captureLoginShellEnvironment() -> [String: String]? {
        guard let shell = loginShellPath() else { return nil }
        // Interactive *and* login: `.zshrc`/`.bashrc` are where most people put
        // their PATH edits, and those are only sourced for interactive shells.
        // If that hangs or the shell rejects `-i` without a tty, fall back to a
        // plain login shell, which still picks up `.zprofile`/`.bash_profile`.
        let deadline = Date().addingTimeInterval(totalCaptureTimeout)
        if let captured = capture(
            shell: shell,
            arguments: ["-ilc", dumpCommand],
            timeout: min(captureTimeout, max(0, deadline.timeIntervalSinceNow))
        ) {
            return captured
        }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return nil }
        return capture(
            shell: shell,
            arguments: ["-lc", dumpCommand],
            timeout: min(captureTimeout, remaining)
        )
    }

    /// Runs `shell arguments`, reading its stdout without ever blocking past
    /// `timeout`, and parses the marked env dump out of the result.
    static func capture(shell: String, arguments: [String], timeout: TimeInterval) -> [String: String]? {
        guard let process = spawnCapture(shell: shell, arguments: arguments) else { return nil }
        let output = readOutput(from: process.outputFD, timeout: timeout)
        _ = Darwin.close(process.outputFD)
        terminateCaptureProcessGroup(process.identifier)
        return parse(output)
    }

    private struct CaptureProcess {
        let identifier: pid_t
        let outputFD: Int32
    }

    /// Login-shell startup files can launch children of their own. Spawn the
    /// capture as an atomic process-group leader so timeout/early-abort cleanup
    /// owns the whole tree instead of leaking an rc-file descendant.
    private static func spawnCapture(shell: String, arguments: [String]) -> CaptureProcess? {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard descriptors.withUnsafeMutableBufferPointer({ pipe($0.baseAddress!) }) == 0 else {
            return nil
        }
        let readFD = descriptors[0]
        let writeFD = descriptors[1]

        func closeDescriptors() {
            _ = Darwin.close(readFD)
            _ = Darwin.close(writeFD)
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
            return nil
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        setupError = posix_spawnattr_init(&attributes)
        guard setupError == 0 else {
            closeDescriptors()
            return nil
        }
        defer { posix_spawnattr_destroy(&attributes) }

        setupError = posix_spawn_file_actions_adddup2(&fileActions, writeFD, STDOUT_FILENO)
        if setupError == 0 {
            setupError = posix_spawn_file_actions_addopen(
                &fileActions, STDERR_FILENO, "/dev/null", O_WRONLY, 0
            )
        }
        if setupError == 0 {
            setupError = posix_spawn_file_actions_addopen(
                &fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0
            )
        }
        if setupError == 0 { setupError = posix_spawn_file_actions_addclose(&fileActions, readFD) }
        if setupError == 0 { setupError = posix_spawn_file_actions_addclose(&fileActions, writeFD) }

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
        if setupError == 0 { setupError = posix_spawnattr_setpgroup(&attributes, 0) }
        guard setupError == 0 else {
            closeDescriptors()
            return nil
        }

        let argv = [shell] + arguments
        let environment = ProcessInfo.processInfo.environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        var childPID: pid_t = 0
        let spawnError = shell.withCString { executable in
            withMutableCStringArray(argv) { argumentPointers in
                withMutableCStringArray(environment) { environmentPointers in
                    posix_spawn(
                        &childPID,
                        executable,
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
            return nil
        }

        _ = Darwin.close(writeFD)
        return CaptureProcess(identifier: childPID, outputFD: readFD)
    }

    private static func terminateCaptureProcessGroup(_ identifier: pid_t) {
        // Keep the leader unreaped as a PGID identity anchor until both signals
        // have been sent. Signal the direct PID too in case a shell startup file
        // moved the leader into a different session/group. This also cleans
        // TERM-ignoring children deterministically.
        _ = kill(-identifier, SIGTERM)
        _ = kill(identifier, SIGTERM)
        // A bounded grace preserves the overall capture timeout contract. The
        // direct leader is SIGKILLed afterward, so waitpid cannot hang even if
        // it ignored TERM or moved out of the original process group.
        usleep(50_000)
        _ = kill(-identifier, SIGKILL)
        _ = kill(identifier, SIGKILL)

        var status: Int32 = 0
        var result: pid_t
        repeat {
            result = waitpid(identifier, &status, 0)
        } while result == -1 && errno == EINTR
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

    /// Reads until EOF, the end marker, or the deadline — whichever comes
    /// first. Deliberately poll-based on the calling thread: a shell that
    /// backgrounds something holding the write end never sends EOF, and a
    /// blocking `readToEnd()` would strand a thread on it forever.
    private static func readOutput(from fd: Int32, timeout: TimeInterval) -> Data {
        let flags = fcntl(fd, F_GETFL)
        if flags != -1 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }

        let deadline = Date().addingTimeInterval(timeout)
        let endMarker = Data(Self.endMarker.utf8)
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)

        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining * 1000, 250).rounded(.up)))
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { continue }

            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                guard output.count + count <= maximumCaptureBytes else {
                    output.removeAll(keepingCapacity: false)
                    break
                }
                output.append(contentsOf: buffer[0..<count])
                if output.range(of: endMarker) != nil { break }
            } else if count == 0 {
                break // EOF
            } else if errno == EAGAIN || errno == EINTR {
                continue
            } else {
                break
            }
        }
        return output
    }

    /// Extracts the NUL-separated `KEY=VALUE` pairs between the markers.
    /// Returns nil when the dump never appeared, so the caller can fall back
    /// instead of adopting a half-written environment.
    static func parse(_ data: Data) -> [String: String]? {
        guard let begin = data.range(of: Data(beginMarker.utf8)),
              let end = data.range(of: Data(endMarker.utf8), in: begin.upperBound..<data.endIndex)
        else { return nil }

        var environment: [String: String] = [:]
        for entry in data[begin.upperBound..<end.lowerBound].split(separator: 0, omittingEmptySubsequences: true) {
            guard let separator = entry.firstIndex(of: UInt8(ascii: "=")), separator > entry.startIndex else { continue }
            let key = String(decoding: entry[entry.startIndex..<separator], as: UTF8.self)
            let value = String(decoding: entry[entry.index(after: separator)...], as: UTF8.self)
            environment[key] = value
        }
        return environment
    }
}
