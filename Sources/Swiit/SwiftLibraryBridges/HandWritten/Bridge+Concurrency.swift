import Foundation

// Swift's `Task`, bridged by hand: its operation is Swiit code, which runs as
// a task of the interpreter's (InterpreterLock.swift), not on Swift's
// executors. The checker reads these members as it reads the generator's.
// Docs/async.md, step 7.

/// A `Task`'s value: the interpreter's task it started.
final class TaskBox: @unchecked Sendable {  // safe: only immutable state
    let handle: ScriptTask
    init(_ handle: ScriptTask) { self.handle = handle }
}

/// What `Task.checkCancellation()`, `Task.sleep` and a cancelled task's
/// `value` throw: Swift's `CancellationError`.
func cancellationError() -> RuntimeError {
    RuntimeError(
        "the task was cancelled",
        thrown: Value(
            record:
                Value.Record(
                    ["localizedDescription": .string("the task was cancelled")],
                    typeName: "CancellationError"
                )
        )
    )
}

extension Bridge {
    /// Conformances this module declares for bridged types, which the
    /// generator doesn't read (it reads the modules the types are from).
    static let conformancesDeclaredHere: [String: [String]] = [
        "TaskGroup": ["AsyncSequence"],
        "ThrowingTaskGroup": ["AsyncSequence"],
    ]

    static let concurrency: [BridgedType] = ([taskType] + taskGroupTypes)
        .map {
            BridgedType(generated: $0)
        }

    private static func task(_ value: Value) throws -> ScriptTask {
        try SwiftValue.unbox(TaskBox.self, value).handle
    }

    /// `Task { }`: runs the operation as an unstructured task, as Swift's `Task { }` does: it
    /// isn't cancelled when the scope that made it ends.
    private static func start(_ arguments: [Value]) throws -> Value {
        let interpreter = try running()
        let operation = arguments[0]
        let handle = try interpreter.startTask(
            host: interpreter.host.makeTaskState(),
            structured: false
        ) {
            try interpreter.call(operation, with: [])
        }
        return SwiftValue.make(TaskBox(handle), as: "Task")
    }

    private static let taskType: HostType = {
        var type = HostType(name: "Task", members: taskMembers)
        type.genericParameters = ["Success", "Failure"]
        type.conformances = ["Hashable": [], "Equatable": []]
        return type
    }()

    private static let taskMembers: [HostSymbol] = [
        .initializer(
            summary:
                "Runs the operation as a task of its own, which goes on while the code that started it does.",
            attributes: discardable,
            signature: Symbol.Function(
                parameters: [
                    Symbol.Parameter(
                        label: "operation",
                        name: "operation",
                        type: .function(
                            parameters: [],
                            returns: .parameter("Success"),
                            isAsync: true
                        )
                    )
                ],
                returns: .named("Task", [.parameter("Success"), .named("Never")]),
                generics: ["Success"]
            ),
            body: start
        ),
        .initializer(
            summary:
                "Runs the throwing operation as a task of its own, which goes on while the code that started it does.",
            attributes: discardable,
            signature: Symbol.Function(
                parameters: [
                    Symbol.Parameter(
                        label: "operation",
                        name: "operation",
                        type: .function(
                            parameters: [],
                            returns: .parameter("Success"),
                            isThrowing: true,
                            isAsync: true
                        )
                    )
                ],
                returns: .named("Task", [.parameter("Success"), .named("Error")]),
                generics: ["Success"]
            ),
            body: start
        ),
        .property(
            "value",
            summary: "What the task gives, once it has ended; what it threw, if it threw.",
            type: .parameter("Success"),
            isAsync: true,
            throwing: .typed(.parameter("Failure"))
        ) { receiver in
            let handle = try task(receiver)
            do {
                return try running().joinTask(handle)
            } catch is Cancelled {
                // The task, not the one waiting, was cancelled.
                if case .failure(let error)? = handle.rawResult, error is Cancelled {
                    throw cancellationError()
                }
                throw Cancelled()
            }
        },
        .method("cancel", summary: "Asks the task to stop.") { receiver, _ in
            try task(receiver).cancel()
            return .nothing
        },
        .property(
            "isCancelled",
            summary: "Whether the task has been asked to stop.",
            type: .bool
        ) { receiver in
            .bool(try task(receiver).context.cancellation.isSet)
        },
        .staticProperty(
            "isCancelled",
            summary: "Whether the task running this has been asked to stop.",
            type: .bool
        ) {
            .bool(try running().task.cancellation.isSet)
        },
        .staticMethod(
            "checkCancellation",
            summary: "Throws a CancellationError if the task running this has been asked to stop.",
            isThrowing: true
        ) { _ in
            if try running().task.cancellation.isSet { throw cancellationError() }
            return .nothing
        },
        .staticMethod(
            "sleep",
            summary:
                "Waits for at least the given number of nanoseconds, letting other tasks run; throws a CancellationError if the task is cancelled first.",
            parameters: [Symbol.Parameter(label: "nanoseconds", name: "duration", type: .int)],
            isThrowing: true,
            isAsync: true
        ) { arguments in
            let nanoseconds = try Int(arguments[0])
            try running()
                .sleep(until: Date(timeIntervalSinceNow: Double(max(nanoseconds, 0)) / 1e9))
            return .nothing
        },
        .staticMethod(
            "yield",
            summary: "Lets other tasks run before this one goes on.",
            isAsync: true
        ) { _ in
            _ = try running().suspend { sched_yield() }
            return .nothing
        },
    ]
}

extension Interpreter {
    /// Waits until `deadline`, letting other tasks run; a cancelled task
    /// stops waiting, with a CancellationError.
    func sleep(until deadline: Date) throws {
        let cancellation = task.cancellation
        let condition = NSCondition()
        suspend(wake: {
            condition.lock()
            condition.broadcast()
            condition.unlock()
        }) {
            condition.lock()
            while !cancellation.isSet && Date() < deadline { _ = condition.wait(until: deadline) }
            condition.unlock()
        }
        if cancellation.isSet { throw cancellationError() }
    }
}

// Swift's `async` functions, bridged (the generator's glue): a call is a wait
// in `suspend`, and a Swiit closure Swift calls as `async` runs on a thread of
// the interpreter's, as the task that passed it.
