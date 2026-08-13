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

    /// Markers bracket the dump so shell startup noise printed by rc files
    /// (banners, version managers, `echo`s) can't be mistaken for variables.
    private static let beginMarker = "__LAUNCHER_ENV_BEGIN__"
    private static let endMarker = "__LAUNCHER_ENV_END__"
    private static let dumpCommand =
        "printf '%s' '\(beginMarker)'; /usr/bin/env -0; printf '%s' '\(endMarker)'"

    /// Long enough for a heavyweight `.zshrc` (oh-my-zsh, version managers) on
    /// a cold start, short enough that a pathological one can't wedge the app.
    private static let captureTimeout: TimeInterval = 5

    /// Variables that describe the *capturing* shell rather than the user's
    /// configuration. `PWD`/`OLDPWD` would contradict the working directory we
    /// set for the script, and `_` is the shell's own last-argument scratch.
    private static let transientVariables: Set<String> = ["PWD", "OLDPWD", "_"]

    private let lock = NSLock()
    private var cached: [String: String]?
    private let capture: () -> [String: String]?

    /// - Parameter capture: Overridable for tests; returns nil when the login
    ///   shell can't be interrogated, which falls back to the app's own
    ///   environment (the pre-existing behavior).
    init(capture: @escaping () -> [String: String]? = { ShellEnvironment.captureLoginShellEnvironment() }) {
        self.capture = capture
    }

    /// The environment to hand to spawned scripts. Blocks on the first call
    /// while the login shell is interrogated (bounded by `captureTimeout`);
    /// call `prewarm()` at startup so that cost is paid off the main thread.
    func resolved() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }

        // Start from our own environment so launchd-provided essentials
        // (HOME, TMPDIR, __CF_USER_TEXT_ENCODING…) survive even if the shell
        // dump is unusable, then let the shell's values win where they differ.
        var environment = ProcessInfo.processInfo.environment
        if let captured = capture() {
            for (key, value) in captured where !Self.transientVariables.contains(key) {
                environment[key] = value
            }
        }
        Self.transientVariables.forEach { environment.removeValue(forKey: $0) }
        cached = environment
        return environment
    }

    /// Resolves the environment in the background so the first script run
    /// doesn't wait on a cold shell startup.
    func prewarm() {
        DispatchQueue.global(qos: .utility).async { _ = self.resolved() }
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
        return capture(shell: shell, arguments: ["-ilc", dumpCommand], timeout: captureTimeout)
            ?? capture(shell: shell, arguments: ["-lc", dumpCommand], timeout: captureTimeout)
    }

    /// Runs `shell arguments`, reading its stdout without ever blocking past
    /// `timeout`, and parses the marked env dump out of the result.
    static func capture(shell: String, arguments: [String], timeout: TimeInterval) -> [String: String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        // Interactive rc files chatter on stderr; discard it rather than let it
        // interleave into the dump. stdin must be closed so a shell that tries
        // to read (a prompt, a version-manager wizard) gets EOF instead of
        // hanging until the timeout.
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let output = readOutput(from: pipe.fileHandleForReading, timeout: timeout)
        try? pipe.fileHandleForReading.close()
        if process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        return parse(output)
    }

    /// Reads until EOF, the end marker, or the deadline — whichever comes
    /// first. Deliberately poll-based on the calling thread: a shell that
    /// backgrounds something holding the write end never sends EOF, and a
    /// blocking `readToEnd()` would strand a thread on it forever.
    private static func readOutput(from handle: FileHandle, timeout: TimeInterval) -> Data {
        let fd = handle.fileDescriptor
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
