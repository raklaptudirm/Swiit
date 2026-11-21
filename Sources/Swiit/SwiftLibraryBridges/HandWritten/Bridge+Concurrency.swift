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

    static let concurrency: [ImplementedType] =
        ([taskType, durationType, priorityType] + taskGroupTypes)
        .map {
            $0.lowering(ofTheCore: true)
        }

    private static func task(_ value: Value) throws -> ScriptTask {
        try SwiftValue.unbox(TaskBox.self, value).handle
    }

    /// `Task(priority:) { }`: runs the operation as an unstructured task, as Swift's `Task { }`
    /// does: it isn't cancelled when the scope that made it ends, and it has the priority of the
    /// task that started it unless one is given.
    private static func start(_ arguments: [Value]) throws -> Value {
        try start(arguments, inheritsPriority: true)
    }

    /// `Task.detached(priority:) { }`: the same, with the default priority unless one is given.
    private static func startDetached(_ arguments: [Value]) throws -> Value {
        try start(arguments, inheritsPriority: false)
    }

    private static func start(_ arguments: [Value], inheritsPriority: Bool) throws -> Value {
        let interpreter = try running()
        let operation = arguments[1]
        let given = arguments[0] == .nothing ? nil : try TaskPriority(arguments[0])
        let handle = try interpreter.startTask(
            host: interpreter.host.makeTaskState(),
            structured: false,
            priority: given ?? (inheritsPriority ? interpreter.task.priority : .medium)
        ) {
            try interpreter.call(operation, with: [])
        }
        return SwiftValue.make(TaskBox(handle), as: "Task")
    }

    /// The `priority:` parameter of a task's initializer: left out, it is the starter's.
    private static let priorityParameter = Symbol.Parameter(
        label: "priority",
        name: "priority",
        type: .optional(.named("TaskPriority")),
        arity: .defaulted(.value(.nothing))
    )

    private static func operationParameter(isThrowing: Bool) -> Symbol.Parameter {
        Symbol.Parameter(
            label: "operation",
            name: "operation",
            type: .function(
                parameters: [],
                returns: .parameter("Success"),
                isThrowing: isThrowing,
                isAsync: true
            )
        )
    }

    /// A task that starts one: `Task(priority:operation:)` or, as a function of the type,
    /// `Task.detached(priority:operation:)`.
    private static func starters(
        summary: String,
        initializer: Bool
    ) -> [ImplementedSymbol] {
        [false, true]
            .map { isThrowing in
                let signature = Symbol.Signature(
                    parameters: [priorityParameter, operationParameter(isThrowing: isThrowing)],
                    returns: .named(
                        "Task",
                        [.parameter("Success"), .named(isThrowing ? "Error" : "Never")]
                    ),
                    generics: [Symbol.GenericParameter(name: "Success")]
                )
                return initializer
                    ? .initializer(
                        summary: summary,
                        attributes: discardable,
                        signature: signature,
                        body: start
                    )
                    : .staticMethod(
                        "detached",
                        summary: summary,
                        attributes: discardable,
                        signature: signature,
                        body: startDetached
                    )
            }
    }

    private static let taskType: ImplementedType = {
        var type = ImplementedType(name: "Task", members: taskMembers)
        type.genericParameters = [
            Symbol.GenericParameter(name: "Success"), Symbol.GenericParameter(name: "Failure"),
        ]
        type.conformances = [.hashable: [], .equatable: []]
        return type
    }()

    private static let taskMembers: [ImplementedSymbol] =
        starters(
            summary:
                "Runs the operation as a task of its own, which goes on while the code that started it does.",
            initializer: true
        )
        + starters(
            summary:
                "Runs the operation as a task of its own that has nothing to do with the code that started it, and has the default priority.",
            initializer: false
        ) + taskMembersOfAnInstance

    private static let taskMembersOfAnInstance: [ImplementedSymbol] = [
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
            "sleep",
            summary:
                "Waits for at least the given duration, letting other tasks run; throws a CancellationError if the task is cancelled first.",
            parameters: [
                Symbol.Parameter(label: "for", name: "duration", type: .named("Duration"))
            ],
            isThrowing: true,
            isAsync: true
        ) { arguments in
            let components = try arguments[0].unboxing(Duration.self).components
            let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
            try running().sleep(until: Date(timeIntervalSinceNow: max(seconds, 0)))
            return .nothing
        },
        .staticProperty(
            "currentPriority",
            summary: "The priority of the task running this.",
            type: .named("TaskPriority")
        ) {
            try running().task.priority.value
        },
        .property(
            "priority",
            summary: "The priority the task was started with.",
            type: .named("TaskPriority")
        ) { receiver in
            try task(receiver).context.priority.value
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

extension Duration: BridgedValue {}
extension TaskPriority: BridgedValue {}

extension Bridge {
    /// Swift's `Duration`, to the extent the standard library's `Task.sleep(for:)` needs: made
    /// from a count of a unit, added, subtracted, scaled and compared.
    private static let durationType: ImplementedType = {
        let type = BridgedType<Duration>()
            .static("seconds", labels: [nil]) { (count: Int) in Duration.seconds(count) }
            .static("milliseconds", labels: [nil]) { (count: Int) in Duration.milliseconds(count) }
            .static("microseconds", labels: [nil]) { (count: Int) in Duration.microseconds(count) }
            .static("nanoseconds", labels: [nil]) { (count: Int) in Duration.nanoseconds(count) }
            .static("seconds", labels: [nil]) { (count: Double) in Duration.seconds(count) }
            .static("milliseconds", labels: [nil]) { (count: Double) in
                Duration.milliseconds(count)
            }
            .static("microseconds", labels: [nil]) { (count: Double) in
                Duration.microseconds(count)
            }
        return
            type
            .static("+", labels: [nil, nil]) { (a: Duration, b: Duration) in a + b }
            .static("-", labels: [nil, nil]) { (a: Duration, b: Duration) in a - b }
            .static("*", labels: [nil, nil]) { (a: Duration, b: Int) in a * b }
            .static("/", labels: [nil, nil]) { (a: Duration, b: Int) in a / b }
            .member(
                .staticProperty(
                    "zero",
                    summary: "A duration of no time.",
                    type: .named("Duration")
                ) { Duration.zero.value }
            )
            .type
    }()

    /// Swift's `TaskPriority`: the named priorities and the raw value they compare by.
    private static let priorityType: ImplementedType = {
        var type = BridgedType<TaskPriority>()
        for (name, priority) in [
            ("high", TaskPriority.high), ("medium", .medium), ("low", .low),
            ("userInitiated", .userInitiated), ("utility", .utility), ("background", .background),
        ] {
            type = type.member(
                .staticProperty(name, type: .named("TaskPriority")) { priority.value }
            )
        }
        return
            type.member(
                .property(
                    "rawValue",
                    summary: "The number the priorities are ordered by; a higher one runs sooner.",
                    type: .int
                ) { Value(Int(try $0.unboxing(TaskPriority.self).rawValue)) }
            )
            .type
    }()
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
