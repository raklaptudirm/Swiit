import Foundation

/// What runs Swiit code, told when a function waits: the interpreter, which
/// lets another task run meanwhile (Docs/async.md).
public protocol WaitingHost: AnyObject {
    /// Runs `body`, a wait, letting other tasks run while it does.
    func wait(_ body: () -> Void)
    /// As `wait`, and `wake` is called when the task is cancelled meanwhile, to end the wait early.
    func wait(wake: @escaping () -> Void, _ body: () -> Void)
    /// Runs `body`, a read of the host's input, when it's this task's turn at
    /// the input; or not at all, if the task is cancelled before then.
    func waitForInput(_ body: () -> Void)
}

extension WaitingHost {
    /// A host that can't end a wait early waits it out.
    public func wait(wake: @escaping () -> Void, _ body: () -> Void) { wait(body) }
}

/// For a function that waits, as a host's or a library's may: a blocking
/// read, a network call, a long computation that touches no Swiit values.
/// Wrapped in `whileWaiting`, it lets other Swiit tasks run meanwhile, as
/// the shell's own waits do; unwrapped, it holds every task up while it waits.
///
/// A wait that ends only when `body` returns runs to its end even if the task is cancelled. One that can be cut
/// short (a sleep, a child process, a network call with a cancel handle) says how with `wake`, which is called when
/// the task is cancelled: use `whileWaiting(wake:_:)` for it.
/// The host belongs to the thread that runs the Swiit code calling it.
public enum Waiting {
    private final class Box {
        // Not weak: a weak reference gives the interpreter a side table, which slows every retain and release of
        // it (the whole evaluator) to the slow path. The host outlives the thread's use of it: it is set for
        // the span of its own call (`withMainTask`) or for a task its interpreter waits for.
        unowned(unsafe) var host: WaitingHost?
        init(_ host: WaitingHost?) { self.host = host }
    }

    private static let key = "SwiitKit.Waiting.host"

    /// What runs the Swiit code on this thread, if anything does.
    public static var host: WaitingHost? {
        get { (Thread.current.threadDictionary[key] as? Box)?.host }
        set { Thread.current.threadDictionary[key] = Box(newValue) }
    }

    /// Runs `body`, letting other Swiit tasks run while it waits. It must not
    /// touch the interpreter, or Swiit values that others could change.
    public static func whileWaiting<T>(_ body: () -> T) -> T {
        guard let host else { return body() }
        var result: T?
        host.wait { result = body() }
        return result!
    }

    /// As `whileWaiting`, and `wake` is called if the task is cancelled before `body` returns. It runs on the thread
    /// that cancels, so it may only do what is safe from there: close a handle, signal a process, resume a continuation.
    public static func whileWaiting<T>(wake: @escaping () -> Void, _ body: () -> T) -> T {
        guard let host else { return body() }
        var result: T?
        host.wait(wake: wake) { result = body() }
        return result!
    }

    public static func whileWaiting<T>(_ body: () throws -> T) throws -> T {
        guard let host else { return try body() }
        var result: Result<T, any Error>?
        host.wait { result = Result { try body() } }
        return try result!.get()
    }

    /// Runs `body`, a read of the input, when it's this task's turn at it (a
    /// task in the background waits until it's brought forward); nil if the
    /// task was cancelled first.
    public static func forInput<T>(_ body: () -> T?) -> T? {
        guard let host else { return body() }
        var result: T?
        host.waitForInput { result = body() }
        return result
    }
}
