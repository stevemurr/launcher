import Foundation

/// Stable identity for one independently running shell command.
///
/// Callers should create a new identifier for every submitted command. Keeping
/// identity outside the runner lets a model create its UI state before output
/// can arrive and route background output without relying on the selected job.
struct ShellJobID: Hashable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

protocol ShellJobManaging: AnyObject {
    /// True while at least one accepted job has not delivered completion.
    var isRunning: Bool { get }

    /// Thread-safe snapshot of all accepted jobs awaiting completion.
    var activeJobIDs: Set<ShellJobID> { get }

    /// Starts an independent one-shot shell command. A duplicate active `id` is
    /// rejected without starting a process. Output and completion are delivered
    /// asynchronously on the main queue, with final output preceding completion.
    @discardableResult
    func runShellCommand(
        _ rawCommand: String,
        id: ShellJobID,
        onOutput: @escaping (ShellJobID, String) -> Void,
        onCompletion: @escaping (ShellJobID, ScriptRunResult) -> Void
    ) -> Bool

    /// Requests cancellation of only the identified job. Unknown or already
    /// completed identifiers are ignored.
    func cancel(_ id: ShellJobID)

    /// Immediately terminates every accepted job during application shutdown.
    /// Jobs remain owned until their normal completion callbacks arrive.
    func terminateAllImmediately()
}

/// Adapts the legacy single `ShellCommandRunning` injection point to the
/// identity-scoped manager API. This intentionally preserves the wrapped
/// runner's callback timing instead of adding an asynchronous dispatch hop.
/// Production plural jobs use `ProcessShellJobManager` below.
final class SingleRunnerShellJobManager: ShellJobManaging {
    private enum Phase {
        case starting
        case running
    }

    private enum PendingStop {
        case cancel
        case terminateImmediately
    }

    private final class ActiveJob {
        let id: ShellJobID
        var phase: Phase = .starting
        var pendingStop: PendingStop?

        init(id: ShellJobID) {
            self.id = id
        }
    }

    private let lock = NSLock()
    private let runner: ShellCommandRunning
    private var activeJob: ActiveJob?

    init(runner: ShellCommandRunning) {
        self.runner = runner
    }

    deinit {
        lock.lock()
        let shouldTerminate = activeJob != nil
        activeJob = nil
        lock.unlock()
        if shouldTerminate { runner.terminateImmediately() }
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeJob != nil
    }

    var activeJobIDs: Set<ShellJobID> {
        lock.lock()
        defer { lock.unlock() }
        return activeJob.map { [$0.id] } ?? []
    }

    @discardableResult
    func runShellCommand(
        _ rawCommand: String,
        id: ShellJobID,
        onOutput: @escaping (ShellJobID, String) -> Void,
        onCompletion: @escaping (ShellJobID, ScriptRunResult) -> Void
    ) -> Bool {
        let job = ActiveJob(id: id)

        lock.lock()
        guard activeJob == nil else {
            lock.unlock()
            return false
        }
        activeJob = job
        lock.unlock()

        let accepted = runner.runShellCommand(
            rawCommand,
            onOutput: { [weak self, weak job] chunk in
                guard let self, let job, self.contains(job) else { return }
                onOutput(id, chunk)
            },
            onCompletion: { [weak self, weak job] result in
                guard let self, let job, self.remove(job) else { return }
                onCompletion(id, result)
            }
        )

        let pendingStop: PendingStop?
        lock.lock()
        if activeJob === job, accepted {
            job.phase = .running
            pendingStop = job.pendingStop
        } else {
            if activeJob === job { activeJob = nil }
            pendingStop = nil
        }
        lock.unlock()

        apply(pendingStop)
        return accepted
    }

    func cancel(_ id: ShellJobID) {
        let shouldCancel: Bool
        lock.lock()
        if let job = activeJob, job.id == id, job.pendingStop == nil {
            job.pendingStop = .cancel
            shouldCancel = job.phase == .running
        } else {
            shouldCancel = false
        }
        lock.unlock()

        if shouldCancel { runner.cancel() }
    }

    func terminateAllImmediately() {
        let shouldTerminate: Bool
        lock.lock()
        if let job = activeJob, job.pendingStop != .terminateImmediately {
            job.pendingStop = .terminateImmediately
            shouldTerminate = job.phase == .running
        } else {
            shouldTerminate = false
        }
        lock.unlock()

        if shouldTerminate { runner.terminateImmediately() }
    }

    private func contains(_ job: ActiveJob) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeJob === job
    }

    @discardableResult
    private func remove(_ job: ActiveJob) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeJob === job else { return false }
        activeJob = nil
        return true
    }

    private func apply(_ stop: PendingStop?) {
        switch stop {
        case .cancel: runner.cancel()
        case .terminateImmediately: runner.terminateImmediately()
        case nil: break
        }
    }
}

/// Owns one single-run `ProcessScriptRunner` per active shell job. Keeping the
/// existing runner single-process preserves its process-group, streaming, and
/// cancellation invariants while allowing shell jobs to execute concurrently.
final class ProcessShellJobManager: ShellJobManaging {
    private enum PendingStop {
        case cancel
        case terminateImmediately
    }

    private final class ActiveJob {
        let runner: ShellCommandRunning
        var pendingStop: PendingStop?

        init(runner: ShellCommandRunning) {
            self.runner = runner
        }
    }

    private let lock = NSLock()
    private var activeJobs: [ShellJobID: ActiveJob] = [:]
    private let runnerFactory: () -> ShellCommandRunning

    init(runnerFactory: @escaping () -> ShellCommandRunning = { ProcessScriptRunner() }) {
        self.runnerFactory = runnerFactory
    }

    deinit {
        // Do not depend on ProcessScriptRunner.deinit's graceful escalation when
        // the manager itself disappears (most importantly during app shutdown).
        // Snapshot under the lock, then invoke runners after unlocking because a
        // test double or future runner may synchronously re-enter a callback.
        lock.lock()
        let runners = activeJobs.values.map(\.runner)
        activeJobs.removeAll()
        lock.unlock()
        runners.forEach { $0.terminateImmediately() }
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !activeJobs.isEmpty
    }

    var activeJobIDs: Set<ShellJobID> {
        lock.lock()
        defer { lock.unlock() }
        return Set(activeJobs.keys)
    }

    @discardableResult
    func runShellCommand(
        _ rawCommand: String,
        id: ShellJobID,
        onOutput: @escaping (ShellJobID, String) -> Void,
        onCompletion: @escaping (ShellJobID, ScriptRunResult) -> Void
    ) -> Bool {
        let job = ActiveJob(runner: runnerFactory())

        lock.lock()
        guard activeJobs[id] == nil else {
            lock.unlock()
            return false
        }
        activeJobs[id] = job
        lock.unlock()

        let accepted = job.runner.runShellCommand(
            rawCommand,
            onOutput: { [weak self, weak job] chunk in
                DispatchQueue.main.async {
                    guard let self, let job, self.contains(job, for: id) else { return }
                    onOutput(id, chunk)
                }
            },
            onCompletion: { [weak self, weak job] result in
                DispatchQueue.main.async {
                    guard let self, let job, self.remove(job, for: id) else { return }
                    onCompletion(id, result)
                }
            }
        )

        guard accepted else {
            _ = remove(job, for: id)
            return false
        }

        // Cancellation can race the small interval between publishing the job
        // and the child runner reserving its process slot. Repeat any pending
        // request after acceptance so an early no-op cannot leave a job running.
        let pendingStop: PendingStop?
        lock.lock()
        pendingStop = activeJobs[id] === job ? job.pendingStop : nil
        lock.unlock()
        apply(pendingStop, to: job.runner)
        return true
    }

    func cancel(_ id: ShellJobID) {
        let runner: ShellCommandRunning?
        lock.lock()
        if let job = activeJobs[id], job.pendingStop == nil {
            job.pendingStop = .cancel
            runner = job.runner
        } else {
            runner = nil
        }
        lock.unlock()

        runner?.cancel()
    }

    func terminateAllImmediately() {
        let runners: [ShellCommandRunning]
        lock.lock()
        runners = activeJobs.values.compactMap { job in
            guard job.pendingStop != .terminateImmediately else { return nil }
            job.pendingStop = .terminateImmediately
            return job.runner
        }
        lock.unlock()

        runners.forEach { $0.terminateImmediately() }
    }

    private func contains(_ job: ActiveJob, for id: ShellJobID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeJobs[id] === job
    }

    @discardableResult
    private func remove(_ job: ActiveJob, for id: ShellJobID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeJobs[id] === job else { return false }
        activeJobs.removeValue(forKey: id)
        return true
    }

    private func apply(_ stop: PendingStop?, to runner: ShellCommandRunning) {
        switch stop {
        case .cancel: runner.cancel()
        case .terminateImmediately: runner.terminateImmediately()
        case nil: break
        }
    }
}
