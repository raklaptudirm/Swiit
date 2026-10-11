import SwishKit

/// A line of execution through Swish code: its own call stack (the scopes
/// of the calls and blocks it is in, under the global ones every task
/// shares), its own cancellation flag, and what its host keeps for it, as the
/// shell does its standard output. The prompt is the first task, and for now
/// the only one (Docs/Design/async.md, step 1); the interpreter's own state of
/// these names is the current task's.
@_spi(Shell) public final class TaskContext {
    /// Variable scopes, innermost last. The outermost two are the global
    /// ones every task shares: the builtins, then what is declared at the
    /// prompt, so a `func` there shadows a builtin rather than overloading it.
    @_spi(Shell) public var scopes: [Scope]
    /// How many Swish function calls are in progress.
    @_spi(Shell) public var callDepth = 0
    /// The return types of the functions being run, innermost last, so a
    /// returned `.case` knows its enum.
    @_spi(Shell) public var returnTypes: [TypeAnnotation?] = []
    /// Per-item errors reported so far, like a file `ls` couldn't read.
    @_spi(Shell) public var itemErrorCount = 0
    /// Asks the task to stop, from any thread.
    @_spi(Shell) public let cancellation = Cancellation()
    /// What the host keeps for the task (the shell: its output, its status).
    @_spi(Shell) public var host: AnyObject?
    /// Whether the host's interrupts (the shell's ^C) stop it: the task in the
    /// foreground's do; a background task stops only when it's cancelled.
    @_spi(Shell) public var receivesInterrupts = true
    /// The tasks it started and hasn't seen end, with how deep in its calls
    /// it was: each belongs to the scope that started it, which cancels and
    /// waits for it as it closes.
    @_spi(Shell) public var children: [(depth: Int, handle: TaskHandle)] = []

    @_spi(Shell) public init(globals: [Scope], host: AnyObject? = nil) {
        self.scopes = globals
        self.host = host
    }
}

extension Interpreter {
    /// The current task's scopes, innermost last.
    @_spi(Shell) public var scopes: [Scope] {
        _read { yield task.scopes }
        _modify { yield &task.scopes }
    }

    /// How many Swish function calls the current task has in progress.
    @_spi(Shell) public var callDepth: Int {
        _read { yield task.callDepth }
        _modify { yield &task.callDepth }
    }

    /// The return types of the functions the current task is running.
    @_spi(Shell) public var returnTypes: [TypeAnnotation?] {
        _read { yield task.returnTypes }
        _modify { yield &task.returnTypes }
    }

    /// Per-item errors the current task has reported so far.
    @_spi(Shell) public var itemErrorCount: Int {
        _read { yield task.itemErrorCount }
        _modify { yield &task.itemErrorCount }
    }

    /// Asks the current task to stop, from any thread.
    @_spi(Shell) public var cancellation: Cancellation { task.cancellation }
}

extension Interpreter {
    /// Where the current task waits for something outside itself: a program
    /// to finish, a `$(…)`'s output, a job, the next item of a `Flow` or line
    /// of input. Every wait goes through here; with one task it is just the
    /// wait, and it is where the async evaluator will let another task run
    /// (Docs/Design/async.md, step 2).
    /// `wake` ends the wait early if the task is cancelled meanwhile (by
    /// stopping the programs it waits for, say); the task then stops at its
    /// next step.
    @_spi(Shell) public func suspend<T>(wake: (() -> Void)? = nil, _ wait: () throws -> T) rethrows -> T {
        let mine = task
        let token = wake.map { mine.cancellation.onRequest($0) }
        defer { token.map { mine.cancellation.remove($0) } }
        // Another task runs meanwhile, if one is ready.
        guard lock.isHeldByCurrentThread else { return try wait() }
        defer { task = mine }
        return try lock.releasing(wait)
    }

    /// Closes the scopes deeper than `depth` in the current task: the tasks
    /// they started are cancelled and waited for, as a scope closing does.
    @_spi(Shell) public func closeTasks(above depth: Int) {
        var closing: [TaskHandle] = []
        while let last = task.children.last, last.depth > depth {
            closing.append(task.children.removeLast().handle)
        }
        closing.forEach { $0.cancel() }
        for handle in closing { _ = try? join(handle) }
    }
}

extension Interpreter {
    /// Runs `body` as the main task, holding the lock: how the host enters
    /// the interpreter (a background task may have run last, and left itself
    /// current).
    @_spi(Shell) public func withMainTask<T>(_ body: () throws -> T) rethrows -> T {
        lock.acquire()
        let previous = task
        let previousHost = Waiting.host
        task = mainTask
        Waiting.host = self
        defer {
            task = previous
            Waiting.host = previousHost
            lock.release()
        }
        return try body()
    }
}

/// A function that waits (a plugin's, a library's) lets other tasks run: a
/// plain wait is a `suspend`, and a read of the input waits first for the
/// task's turn at it, which the host says (`inputTurn`).
extension Interpreter: WaitingHost {
    public func wait(_ body: () -> Void) {
        suspend { body() }
    }

    public func waitForInput(_ body: () -> Void) {
        if let inputTurn { inputTurn(body) } else { suspend { body() } }
    }
}
