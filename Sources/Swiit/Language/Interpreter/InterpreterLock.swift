import Foundation
import SwiitKit

/// The one lock Swish code runs under (Docs/Design/async.md, "B"). Tasks
/// run on threads of their own, and only the thread holding the lock runs
/// Swish code or touches the interpreter, so Swish code never runs in
/// parallel and the language needs no locks of its own. A task lets go only
/// to wait (`Interpreter.suspend`), so state changes under it only across a
/// wait. The thread that holds it may take it again.
@_spi(Host) public final class InterpreterLock: @unchecked Sendable {
    private let condition = NSCondition()
    private var holder: pthread_t?
    private var depth = 0

    @_spi(Host) public init() {}

    private var isHolder: Bool {
        guard let holder else { return false }
        return pthread_equal(holder, pthread_self()) != 0
    }

    /// Whether the thread asking holds it.
    @_spi(Host) public var isHeldByCurrentThread: Bool {
        condition.lock()
        defer { condition.unlock() }
        return isHolder
    }

    @_spi(Host) public func acquire() {
        condition.lock()
        defer { condition.unlock() }
        if isHolder {
            depth += 1
            return
        }
        while holder != nil { condition.wait() }
        holder = pthread_self()
        depth = 1
    }

    @_spi(Host) public func release() {
        condition.lock()
        defer { condition.unlock() }
        precondition(isHolder, "the interpreter lock released by a thread that doesn't hold it")
        depth -= 1
        if depth == 0 {
            holder = nil
            condition.broadcast()
        }
    }

    /// Runs `body` holding the lock.
    @_spi(Host) public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        acquire()
        defer { release() }
        return try body()
    }

    /// Lets go of the lock entirely while `wait` runs, and takes it back as
    /// deep as it was held.
    func releasing<T>(_ wait: () throws -> T) rethrows -> T {
        condition.lock()
        let held = depth
        holder = nil
        depth = 0
        condition.broadcast()
        condition.unlock()
        defer {
            condition.lock()
            while holder != nil { condition.wait() }
            holder = pthread_self()
            depth = held
            condition.unlock()
        }
        return try wait()
    }
}

/// A task running Swish code on a thread of its own, from
/// `Interpreter.startTask`: joined by `Interpreter.join`, which waits for it.
@_spi(Host) public final class TaskHandle: @unchecked Sendable {
    @_spi(Host) public let context: TaskContext
    private let condition = NSCondition()
    private var outcome: Result<Value, any Error>?

    init(context: TaskContext) {
        self.context = context
    }

    /// How it ended, once it has.
    @_spi(Host) public var result: Result<Value, any Error>? {
        condition.lock()
        defer { condition.unlock() }
        return outcome
    }

    @_spi(Host) public var isFinished: Bool { result != nil }

    /// Asks it to stop: it notices at its next interrupt check.
    @_spi(Host) public func cancel() { context.cancellation.request() }

    func finish(_ result: Result<Value, any Error>) {
        condition.lock()
        outcome = result
        condition.broadcast()
        condition.unlock()
    }

    /// Blocks until it has ended, or the waiting task is cancelled (nil).
    /// (Through `suspend`, so the lock is let go.)
    func wait(unless cancellation: Cancellation) -> Result<Value, any Error>? {
        condition.lock()
        defer { condition.unlock() }
        while outcome == nil && !cancellation.isSet { condition.wait() }
        return outcome
    }

    /// Wakes whoever is waiting for it, to look again.
    func poke() {
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }
}

extension Interpreter {
    /// Starts `body` as a task of its own, on a thread the host makes: it
    /// runs when the lock is let go, as the task that starts it waits. `host`
    /// is what the host keeps for the task. A background task takes no
    /// interrupts of the host's; it stops when it's cancelled. A structured
    /// task ends with the scope that started it (`closeTasks`); Swift's
    /// `Task { }` isn't one.
    @_spi(Host) public func startTask(host taskHost: AnyObject?, structured: Bool = true,
                                       _ body: @escaping () throws -> Value) throws -> TaskHandle {
        guard runningTasks < limits.tasks else {
            throw RuntimeError("there are already \(limits.tasks) tasks running")
        }
        let context = TaskContext(globals: Array(scopes.prefix(2)), host: taskHost)
        context.receivesInterrupts = false
        let handle = TaskHandle(context: context)
        runningTasks += 1
        if structured { task.children.append((callDepth, handle)) }
        // The interpreter and the task are touched only holding the lock,
        // which the thread takes first: that is what makes this safe.
        nonisolated(unsafe) let body = body
        nonisolated(unsafe) let interpreter = self
        nonisolated(unsafe) let taskContext = context
        host.startThread {
            interpreter.lock.acquire()
            interpreter.task = taskContext
            Waiting.host = interpreter
            var result = Result { try body() }
            // Its own tasks end with it.
            interpreter.closeTasks(above: -1)
            if case .failure(let error) = result, error is Cancelled { result = .failure(Cancelled()) }
            interpreter.runningTasks -= 1
            handle.finish(result)
            interpreter.lock.release()
        }
        return handle
    }

    /// Waits for a task to end, letting go of the lock meanwhile, and gives
    /// what it gave or throws what it threw.
    @_spi(Host) public func join(_ handle: TaskHandle) throws -> Value {
        let waiter = task.cancellation
        // The host may bring it forward while it's awaited (the shell: to the foreground).
        let restore = awaitingTask?(handle)
        defer { restore?() }
        guard let result = suspend(wake: { handle.poke() }, { handle.wait(unless: waiter) }) else {
            // The task waiting was cancelled: it stops, and leaves the other running.
            throw Cancelled()
        }
        return try result.get()
    }
}
