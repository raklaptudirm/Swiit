import Foundation
import SwishKit
import SwishStandardLibrary

// Swift's `Task`, bridged by hand: its operation is Swish code, which runs as
// a task of the interpreter's (InterpreterLock.swift), not on Swift's
// executors. The checker reads these members as it reads the generator's.
// Docs/Design/async.md, step 7.

/// A `Task`'s value: the interpreter's task it started.
@_spi(Shell) public final class TaskBox: @unchecked Sendable {
    @_spi(Shell) public let handle: TaskHandle
    init(_ handle: TaskHandle) { self.handle = handle }
}

/// What `Task.checkCancellation()`, `Task.sleep` and a cancelled task's
/// `value` throw: Swift's `CancellationError`.
@_spi(Shell) public func cancellationError() -> RuntimeError {
    RuntimeError("the task was cancelled", thrown: .record(Record(
        ["localizedDescription": .string("the task was cancelled")], typeName: "CancellationError")))
}

extension Bridge {
    /// Conformances this module declares for bridged types, which the
    /// generator doesn't read (it reads the modules the types are from).
    static let conformancesDeclaredHere: [String: [String]] = ["Flow": ["AsyncSequence"]]

    nonisolated(unsafe) static let concurrency: [BridgedType] = [
        BridgedType(
            name: "Task", genericParameters: ["Success", "Failure"], conformances: ["Hashable": [:], "Equatable": [:]],
            associatedTypes: [:], members: taskMembers
        ),
    ]

    private static func member(
        _ kind: BridgedMember.Kind, _ name: String, isStatic: Bool = false, parameters: [Parameter] = [],
        returns: TypeAnnotation, generics: [String: [String]] = [:], throwing: Bool = false, effect: Effect = .sync,
        typedThrows: String? = nil, summary: String, _ body: @escaping (Interpreter, [String: Value]) throws -> Value
    ) -> BridgedMember {
        BridgedMember(kind: kind, name: name, isStatic: isStatic, parameters: parameters, returns: returns, generics: generics,
                      isThrowing: throwing, isRethrowing: false, isMutating: false, discardableResult: kind == .initializer,
                      summary: summary, body: .native(body), effect: effect, typedThrows: typedThrows)
    }

    private static func task(_ value: Value?) throws -> TaskHandle {
        try SwiftValue.unbox(TaskBox.self, value ?? .nothing).handle
    }

    /// Runs `operation` as an unstructured task, as Swift's `Task { }` does:
    /// it isn't cancelled when the scope that made it ends.
    private static func start(_ shell: Interpreter, _ arguments: [String: Value]) throws -> Value {
        let operation = arguments["operation"]!
        let handle = try shell.startTask(host: shell.newTaskHost?(), structured: false) {
            try shell.call(operation, with: [])
        }
        return SwiftValue.make(TaskBox(handle), as: "Task")
    }

    nonisolated(unsafe) private static let taskMembers: [BridgedMember] = [
        member(.initializer, "init", isStatic: true,
               parameters: [Parameter(label: "operation", name: "operation", type: .functionType([], .parameter("Success"), async: .async))],
               returns: .generic("Task", [.parameter("Success"), .named("Never")]), generics: ["Success": []],
               summary: "Runs the operation as a task of its own, which goes on while the code that started it does.", start),
        member(.initializer, "init", isStatic: true,
               parameters: [Parameter(label: "operation", name: "operation",
                                      type: .functionType([], .parameter("Success"), throws: true, async: .async))],
               returns: .generic("Task", [.parameter("Success"), .named("Error")]), generics: ["Success": []],
               summary: "Runs the throwing operation as a task of its own, which goes on while the code that started it does.", start),
        member(.property, "value", returns: .parameter("Success"), effect: .async, typedThrows: "Failure",
               summary: "What the task gives, once it has ended; what it threw, if it threw.") { shell, arguments in
            let handle = try task(arguments["self"])
            do {
                return try shell.join(handle)
            } catch is Cancelled {
                // The task, not the one waiting, was cancelled.
                if case .failure(let error)? = handle.result, error is Cancelled { throw cancellationError() }
                throw Cancelled()
            }
        },
        member(.method, "cancel", returns: .void, summary: "Asks the task to stop.") { _, arguments in
            try task(arguments["self"]).cancel()
            return .nothing
        },
        member(.property, "isCancelled", returns: .bool, summary: "Whether the task has been asked to stop.") { _, arguments in
            .bool(try task(arguments["self"]).context.cancellation.isSet)
        },
        member(.property, "isCancelled", isStatic: true, returns: .bool,
               summary: "Whether the task running this has been asked to stop.") { shell, _ in
            .bool(shell.task.cancellation.isSet)
        },
        member(.method, "checkCancellation", isStatic: true, returns: .void, throwing: true,
               summary: "Throws a CancellationError if the task running this has been asked to stop.") { shell, _ in
            if shell.task.cancellation.isSet { throw cancellationError() }
            return .nothing
        },
        member(.method, "sleep", isStatic: true, parameters: [Parameter(label: "nanoseconds", name: "duration", type: .int)],
               returns: .void, throwing: true, effect: .async,
               summary: "Waits for at least the given number of nanoseconds, letting other tasks run; throws a CancellationError if the task is cancelled first.") { shell, arguments in
            let nanoseconds = try Int(swishValue: arguments["duration"]!)
            try shell.sleep(until: Date(timeIntervalSinceNow: Double(max(nanoseconds, 0)) / 1e9))
            return .nothing
        },
        member(.method, "yield", isStatic: true, returns: .void, effect: .async,
               summary: "Lets other tasks run before this one goes on.") { shell, _ in
            shell.suspend { sched_yield() }
            return .nothing
        },
    ]
}

extension Interpreter {
    /// Waits until `deadline`, letting other tasks run; a cancelled task
    /// stops waiting, with a CancellationError.
    @_spi(Shell) public func sleep(until deadline: Date) throws {
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
// in `suspend`, and a Swish closure Swift calls as `async` runs on a thread of
// the interpreter's, as the task that passed it.

/// Runs Swift's `operation` to its end, letting other tasks run meanwhile;
/// cancelling the task cancels it.
@_spi(Shell) public func bridgeAsync(_ shell: Interpreter, _ operation: @escaping () async throws -> Value) throws -> Value {
    // Set by the operation's task, read by this thread once it's set.
    final class Outcome: @unchecked Sendable {
        let operation: () async throws -> Value
        private let condition = NSCondition()
        private var stored: Result<Value, any Error>?
        init(_ operation: @escaping () async throws -> Value) { self.operation = operation }

        func finish(_ result: Result<Value, any Error>) {
            condition.lock()
            stored = result
            condition.broadcast()
            condition.unlock()
        }

        func wait() -> Result<Value, any Error> {
            condition.lock()
            defer { condition.unlock() }
            while stored == nil { condition.wait() }
            return stored!
        }
    }
    let outcome = Outcome(operation)
    let running = Task.detached {
        do { outcome.finish(.success(try await outcome.operation())) } catch { outcome.finish(.failure(error)) }
    }
    let result = shell.suspend(wake: { running.cancel() }) { outcome.wait() }
    if case .failure(is CancellationError) = result { throw cancellationError() }
    return try result.get()
}

/// A Swish closure as Swift's `async` one: each call runs it holding the lock,
/// as the task that passed it, which is waiting in `bridgeAsync` meanwhile.
@_spi(Shell) public func bridgeAsyncClosure(_ shell: Interpreter, _ function: Value) -> ([Value]) async throws -> Value {
    nonisolated(unsafe) let shell = shell
    nonisolated(unsafe) let caller = shell.task
    nonisolated(unsafe) let function = function
    return { arguments in
        nonisolated(unsafe) let arguments = arguments
        return try await withCheckedThrowingContinuation { continuation in
            shell.host.startThread {
                shell.lock.acquire()
                let previous = shell.task
                shell.task = caller
                Waiting.host = shell
                let result = Result { try shell.call(function, with: arguments) }
                shell.task = previous
                shell.lock.release()
                continuation.resume(with: result)
            }
        }
    }
}

/// A Flow read with `for try await`, as Swift reads any asynchronous sequence:
/// reading an item may wait (a job's next line). Declared here rather than
/// with Flow, so the generator doesn't bridge AsyncSequence's own methods,
/// whose iteration would run the Flow's Swish closures off the interpreter's
/// threads.
extension Flow: AsyncSequence {
    public struct AsyncIterator: AsyncIteratorProtocol {
        let read: () throws -> Element?

        public mutating func next() async throws -> Element? { try read() }
    }

    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(read: read) }
}
