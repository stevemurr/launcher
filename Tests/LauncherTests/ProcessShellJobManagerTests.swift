import XCTest
@testable import Launcher

private final class ControllableShellJobRunner: ShellCommandRunning {
    var acceptsRun = true
    private(set) var isRunning = false
    private(set) var commands: [String] = []
    private(set) var cancellationCount = 0
    private(set) var immediateTerminationCount = 0

    private var onOutput: ((String) -> Void)?
    private var onCompletion: ((ScriptRunResult) -> Void)?

    @discardableResult
    func runShellCommand(
        _ rawCommand: String,
        onOutput: @escaping (String) -> Void,
        onCompletion: @escaping (ScriptRunResult) -> Void
    ) -> Bool {
        guard acceptsRun, !isRunning else { return false }
        isRunning = true
        commands.append(rawCommand)
        self.onOutput = onOutput
        self.onCompletion = onCompletion
        return true
    }

    func cancel() {
        cancellationCount += 1
    }

    func terminateImmediately() {
        immediateTerminationCount += 1
    }

    func emit(_ output: String) {
        onOutput?(output)
    }

    /// Deliberately retains the callback after completion. Calling this again
    /// lets tests verify that a stale child cannot affect a reused job ID.
    func finish(_ result: ScriptRunResult) {
        isRunning = false
        onCompletion?(result)
    }
}

private final class ShellJobRunnerFactory {
    private(set) var runners: [ControllableShellJobRunner] = []

    func makeRunner() -> ShellCommandRunning {
        let runner = ControllableShellJobRunner()
        runners.append(runner)
        return runner
    }
}

final class ProcessShellJobManagerTests: XCTestCase {
    func testSingleRunnerAdapterPreservesSynchronousCallbacksAndIdentity() {
        let runner = ControllableShellJobRunner()
        let manager = SingleRunnerShellJobManager(runner: runner)
        let id = ShellJobID()
        let otherID = ShellJobID()
        var callbackEvents: [String] = []

        XCTAssertTrue(manager.runShellCommand(
            "legacy",
            id: id,
            onOutput: { callbackID, output in
                XCTAssertEqual(callbackID, id)
                callbackEvents.append("output:\(output)")
            },
            onCompletion: { callbackID, result in
                XCTAssertEqual(callbackID, id)
                callbackEvents.append("completion:\(result)")
            }
        ))

        runner.emit("now")
        XCTAssertEqual(callbackEvents, ["output:now"])
        manager.cancel(otherID)
        XCTAssertEqual(runner.cancellationCount, 0)
        manager.cancel(id)
        XCTAssertEqual(runner.cancellationCount, 1)
        XCTAssertEqual(manager.activeJobIDs, [id])

        runner.finish(.cancelled)
        XCTAssertEqual(callbackEvents, ["output:now", "completion:cancelled"])
        XCTAssertFalse(manager.isRunning)
    }

    func testSingleRunnerAdapterRejectsSecondActiveID() {
        let runner = ControllableShellJobRunner()
        let manager = SingleRunnerShellJobManager(runner: runner)
        let firstID = ShellJobID()

        XCTAssertTrue(manager.runShellCommand(
            "first",
            id: firstID,
            onOutput: { _, _ in },
            onCompletion: { _, _ in }
        ))
        XCTAssertFalse(manager.runShellCommand(
            "second",
            id: ShellJobID(),
            onOutput: { _, _ in XCTFail("rejected job emitted output") },
            onCompletion: { _, _ in XCTFail("rejected job completed") }
        ))
        XCTAssertEqual(runner.commands, ["first"])

        runner.finish(.success)
        XCTAssertFalse(manager.isRunning)
    }

    func testTwoJobsRunAndCompleteIndependently() {
        let factory = ShellJobRunnerFactory()
        let manager = ProcessShellJobManager(runnerFactory: factory.makeRunner)
        let firstID = ShellJobID()
        let secondID = ShellJobID()
        let outputDelivered = expectation(description: "both outputs delivered")
        outputDelivered.expectedFulfillmentCount = 2
        let completionDelivered = expectation(description: "both completions delivered")
        completionDelivered.expectedFulfillmentCount = 2
        var outputByID: [ShellJobID: String] = [:]
        var resultByID: [ShellJobID: ScriptRunResult] = [:]

        let onOutput: (ShellJobID, String) -> Void = { id, output in
            XCTAssertTrue(Thread.isMainThread)
            outputByID[id, default: ""] += output
            outputDelivered.fulfill()
        }
        let onCompletion: (ShellJobID, ScriptRunResult) -> Void = { id, result in
            XCTAssertTrue(Thread.isMainThread)
            resultByID[id] = result
            completionDelivered.fulfill()
        }

        XCTAssertTrue(manager.runShellCommand(
            "first command",
            id: firstID,
            onOutput: onOutput,
            onCompletion: onCompletion
        ))
        XCTAssertTrue(manager.runShellCommand(
            "second command",
            id: secondID,
            onOutput: onOutput,
            onCompletion: onCompletion
        ))
        XCTAssertEqual(factory.runners.count, 2)
        XCTAssertEqual(manager.activeJobIDs, [firstID, secondID])
        XCTAssertTrue(manager.isRunning)

        factory.runners[0].emit("first output\n")
        factory.runners[1].emit("second output\n")
        factory.runners[1].finish(.failure(exitCode: 7))
        factory.runners[0].finish(.success)

        wait(for: [outputDelivered, completionDelivered], timeout: 2)
        XCTAssertEqual(outputByID[firstID], "first output\n")
        XCTAssertEqual(outputByID[secondID], "second output\n")
        XCTAssertEqual(resultByID[firstID], .success)
        XCTAssertEqual(resultByID[secondID], .failure(exitCode: 7))
        XCTAssertTrue(manager.activeJobIDs.isEmpty)
        XCTAssertFalse(manager.isRunning)
    }

    func testCancellingOneJobLeavesTheOtherActive() {
        let factory = ShellJobRunnerFactory()
        let manager = ProcessShellJobManager(runnerFactory: factory.makeRunner)
        let firstID = ShellJobID()
        let secondID = ShellJobID()
        let firstCompleted = expectation(description: "first completion")
        let secondCompleted = expectation(description: "second completion")

        XCTAssertTrue(manager.runShellCommand(
            "first",
            id: firstID,
            onOutput: { _, _ in },
            onCompletion: { id, result in
                XCTAssertEqual(id, firstID)
                XCTAssertEqual(result, .cancelled)
                firstCompleted.fulfill()
            }
        ))
        XCTAssertTrue(manager.runShellCommand(
            "second",
            id: secondID,
            onOutput: { _, _ in },
            onCompletion: { id, result in
                XCTAssertEqual(id, secondID)
                XCTAssertEqual(result, .success)
                secondCompleted.fulfill()
            }
        ))

        manager.cancel(firstID)

        XCTAssertEqual(factory.runners[0].cancellationCount, 1)
        XCTAssertEqual(factory.runners[1].cancellationCount, 0)
        XCTAssertEqual(manager.activeJobIDs, [firstID, secondID])

        factory.runners[0].finish(.cancelled)
        wait(for: [firstCompleted], timeout: 2)
        XCTAssertEqual(manager.activeJobIDs, [secondID])
        XCTAssertTrue(manager.isRunning)

        factory.runners[1].finish(.success)
        wait(for: [secondCompleted], timeout: 2)
        XCTAssertFalse(manager.isRunning)
    }

    func testTerminateAllTargetsEveryRunnerAndRetainsJobsUntilCompletion() {
        let factory = ShellJobRunnerFactory()
        let manager = ProcessShellJobManager(runnerFactory: factory.makeRunner)
        let identifiers = [ShellJobID(), ShellJobID()]
        let completionDelivered = expectation(description: "all completions")
        completionDelivered.expectedFulfillmentCount = identifiers.count

        for (index, id) in identifiers.enumerated() {
            XCTAssertTrue(manager.runShellCommand(
                "command \(index)",
                id: id,
                onOutput: { _, _ in },
                onCompletion: { _, result in
                    XCTAssertEqual(result, .cancelled)
                    completionDelivered.fulfill()
                }
            ))
        }

        manager.terminateAllImmediately()

        XCTAssertEqual(factory.runners.map(\.immediateTerminationCount), [1, 1])
        XCTAssertEqual(manager.activeJobIDs, Set(identifiers))
        XCTAssertTrue(manager.isRunning)

        factory.runners.forEach { $0.finish(.cancelled) }
        wait(for: [completionDelivered], timeout: 2)
        XCTAssertFalse(manager.isRunning)
    }

    func testStaleCompletionCannotRemoveAReusedIdentifier() {
        let factory = ShellJobRunnerFactory()
        let manager = ProcessShellJobManager(runnerFactory: factory.makeRunner)
        let id = ShellJobID()
        let oldCompleted = expectation(description: "old job completed")
        var deliveredResults: [ScriptRunResult] = []

        XCTAssertTrue(manager.runShellCommand(
            "old",
            id: id,
            onOutput: { _, _ in },
            onCompletion: { _, result in
                deliveredResults.append(result)
                oldCompleted.fulfill()
            }
        ))
        let oldRunner = factory.runners[0]
        oldRunner.finish(.success)
        wait(for: [oldCompleted], timeout: 2)

        let newCompleted = expectation(description: "new job completed")
        XCTAssertTrue(manager.runShellCommand(
            "new",
            id: id,
            onOutput: { _, _ in },
            onCompletion: { _, result in
                deliveredResults.append(result)
                newCompleted.fulfill()
            }
        ))
        let newRunner = factory.runners[1]

        oldRunner.finish(.failure(exitCode: 99))
        let staleCallbackDrained = expectation(description: "stale callback drained")
        DispatchQueue.main.async { staleCallbackDrained.fulfill() }
        wait(for: [staleCallbackDrained], timeout: 2)

        XCTAssertEqual(deliveredResults, [.success])
        XCTAssertEqual(manager.activeJobIDs, [id])
        XCTAssertTrue(newRunner.isRunning)

        newRunner.finish(.cancelled)
        wait(for: [newCompleted], timeout: 2)
        XCTAssertEqual(deliveredResults, [.success, .cancelled])
        XCTAssertFalse(manager.isRunning)
    }

    func testRejectedChildRunDoesNotRemainActive() {
        let runner = ControllableShellJobRunner()
        runner.acceptsRun = false
        let manager = ProcessShellJobManager(runnerFactory: { runner })
        var callbackCount = 0

        XCTAssertFalse(manager.runShellCommand(
            "rejected",
            id: ShellJobID(),
            onOutput: { _, _ in callbackCount += 1 },
            onCompletion: { _, _ in callbackCount += 1 }
        ))

        XCTAssertFalse(manager.isRunning)
        XCTAssertTrue(manager.activeJobIDs.isEmpty)
        XCTAssertEqual(callbackCount, 0)
    }
}
