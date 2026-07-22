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

    private let stateQueue = DispatchQueue(label: "launcher.scriptRunner.state")
    private var process: Process?
    /// True from the moment a run is successfully launched until its
    /// terminationHandler has fully processed the exit, mutated only on
    /// `stateQueue`. Unlike `Process.isRunning` (which flips false the
    /// instant the child exits, before our terminationHandler runs), this
    /// stays true across that window so a second `run()` can't race in and
    /// stomp `self.process` before the first run has finished tearing down.
    private var isActive = false
    private var cancelRequested = false
    private var decoder = UTF8StreamDecoder()
    private var pendingOutput = ""
    private var flushScheduled = false
    /// Set on `stateQueue` once the terminationHandler starts draining and
    /// closing the read end. A readability block queued before that (they share
    /// `stateQueue`) must not touch `availableData` afterward — the descriptor
    /// is gone and FileHandle would raise on it.
    private var isTearingDown = false
    private var onOutput: ((String) -> Void)?

    private static let flushInterval: DispatchTimeInterval = .milliseconds(80)
    private static let killGracePeriod: DispatchTimeInterval = .seconds(2)

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
        let process = Process()
        let pipe = Pipe()

        let started: Bool = stateQueue.sync {
            guard !self.isActive else { return false }

            let isExecutable = FileManager.default.isExecutableFile(atPath: command.url.path)
            if isExecutable {
                process.executableURL = command.url
                process.arguments = arguments
            } else {
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = [command.url.path] + arguments
            }
            process.currentDirectoryURL = command.url.deletingLastPathComponent()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice

            self.cancelRequested = false
            self.decoder = UTF8StreamDecoder()
            self.pendingOutput = ""
            self.flushScheduled = false
            self.isTearingDown = false
            self.onOutput = onOutput

            let handle = pipe.fileHandleForReading
            // Put the read end in non-blocking mode up front so neither the
            // streaming reads below nor the terminationHandler's final drain can
            // ever block this serial queue waiting on EOF. This is critical:
            // stdout+stderr share this pipe, and a backgrounded descendant that
            // inherits the write end can hold it open indefinitely, so a
            // blocking read (availableData/readToEnd) would hang the queue — and
            // every isRunning/cancel() call that syncs on it — until that
            // descendant dies.
            let readFD = handle.fileDescriptor
            let readFlags = fcntl(readFD, F_GETFL)
            if readFlags != -1 { _ = fcntl(readFD, F_SETFL, readFlags | O_NONBLOCK) }
            handle.readabilityHandler = { [weak self] handle in
                guard let self else { return }
                // Read + enqueue on stateQueue so this can't reorder past the
                // terminationHandler's own stateQueue block (which would
                // otherwise miss bytes already pulled off the pipe but not yet
                // appended to pendingOutput).
                self.stateQueue.async {
                    // Once teardown has begun, the read end is being drained and
                    // closed; don't touch it.
                    guard !self.isTearingDown else { return }
                    var buf = [UInt8](repeating: 0, count: 65536)
                    let n = read(handle.fileDescriptor, &buf, buf.count)
                    if n > 0 {
                        self.enqueue(data: Data(buf[0..<n]))
                    } else if n == 0 {
                        handle.readabilityHandler = nil // EOF
                    }
                    // n < 0 (EAGAIN): nothing buffered right now; wait for the
                    // next readable event.
                }
            }

            process.terminationHandler = { [weak self] process in
                guard let self else { return }
                self.stateQueue.async {
                    self.isTearingDown = true
                    // Stop the readability handler, then drain whatever is
                    // already buffered on the pipe with a NON-BLOCKING read.
                    // We deliberately do not use readToEnd()/wait for EOF:
                    // stdout+stderr share this pipe, and if the script
                    // backgrounded a descendant that inherited the write end
                    // (e.g. `sleep 300 &`), EOF never arrives and a blocking
                    // read would hang stateQueue (and, transitively, every
                    // isRunning/cancel() call from the main thread) forever.
                    // The direct child has already exited, so whatever is
                    // already buffered is all we report; output a lingering
                    // descendant writes later is intentionally dropped.
                    pipe.fileHandleForReading.readabilityHandler = nil
                    let fd = pipe.fileHandleForReading.fileDescriptor
                    let flags = fcntl(fd, F_GETFL)
                    if flags != -1 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
                    var remaining = Data()
                    var buf = [UInt8](repeating: 0, count: 65536)
                    while true {
                        // poll() with a 0 ms timeout never blocks; it reports a
                        // positive count only when the fd already has data or has
                        // reached EOF/HUP. This guarantees the drain can't hang
                        // this serial queue waiting on a lingering descendant that
                        // still holds the shared write end open.
                        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                        guard poll(&pfd, 1, 0) > 0 else { break }
                        let n = read(fd, &buf, buf.count)
                        if n > 0 {
                            remaining.append(contentsOf: buf[0..<n])
                        } else {
                            break // 0 = EOF, negative = error
                        }
                    }
                    try? pipe.fileHandleForReading.close()

                    let result: ScriptRunResult
                    if self.cancelRequested {
                        result = .cancelled
                    } else if process.terminationStatus == 0 {
                        result = .success
                    } else {
                        result = .failure(exitCode: process.terminationStatus)
                    }

                    // A superseded run's terminationHandler must not clobber
                    // shared state belonging to a newer run.
                    guard self.process === process else {
                        DispatchQueue.main.async { onCompletion(result) }
                        return
                    }

                    if !remaining.isEmpty {
                        self.pendingOutput += self.decoder.decode(remaining)
                    }
                    self.pendingOutput += self.decoder.flushRemainder()
                    let finalChunk = self.pendingOutput
                    self.pendingOutput = ""
                    self.flushScheduled = true // suppress any queued timer flush

                    let deliverOutput = self.onOutput
                    self.onOutput = nil
                    self.process = nil
                    self.isActive = false

                    DispatchQueue.main.async {
                        if !finalChunk.isEmpty { deliverOutput?(finalChunk) }
                        onCompletion(result)
                    }
                }
            }

            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                pipe.fileHandleForReading.readabilityHandler = nil
                self.onOutput = nil
                DispatchQueue.main.async { onCompletion(.failedToStart(error.localizedDescription)) }
                return true // consumed the attempt; runner stays idle
            }
            self.process = process
            self.isActive = true
            return true
        }

        return started
    }

    func cancel() {
        stateQueue.sync {
            guard let process, process.isRunning else { return }
            cancelRequested = true
            let pid = process.processIdentifier
            process.terminate()
            stateQueue.asyncAfter(deadline: .now() + Self.killGracePeriod) { [weak self] in
                guard let self, self.process?.processIdentifier == pid, self.process?.isRunning == true else { return }
                kill(pid, SIGKILL)
            }
        }
    }

    // MARK: - Output coalescing (on stateQueue)

    private func enqueue(data: Data) {
        pendingOutput += decoder.decode(data)
        guard !flushScheduled else { return }
        flushScheduled = true
        stateQueue.asyncAfter(deadline: .now() + Self.flushInterval) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        flushScheduled = false
        guard !pendingOutput.isEmpty, let onOutput else { return }
        let chunk = pendingOutput
        pendingOutput = ""
        DispatchQueue.main.async { onOutput(chunk) }
    }
}
