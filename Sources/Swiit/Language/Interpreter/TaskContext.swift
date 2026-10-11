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
    @_spi(Shell) public func suspend<T>(_ wait: () throws -> T) rethrows -> T {
        try wait()
    }
}
