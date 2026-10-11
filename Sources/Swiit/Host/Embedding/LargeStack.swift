import Foundation

/// Runs `body` on a thread with a large stack and waits for it. Swiit code
/// recurses in the interpreter, so a run happens on such a thread: the
/// embedder needs no stack setup, and the shell uses it for the same reason.
/// This is the one place the core makes threads.
@_spi(Host) public func onLargeStack<T>(_ body: @escaping () throws -> T) throws -> T {
    // The caller waits for the thread, so nothing runs at the same time.
    nonisolated(unsafe) var result: Result<T, any Error>?
    nonisolated(unsafe) let body = body
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        result = Result { try body() }
        done.signal()
    }
    thread.stackSize = 256 << 20
    thread.start()
    done.wait()
    return try result!.get()
}

/// Starts `body` on a thread with a large stack, and doesn't wait: a task's
/// thread, where the host doesn't make its own (`SwiitHost.startThread`).
public func startLargeStackThread(_ body: @escaping @Sendable () -> Void) {
    let thread = Thread { body() }
    thread.stackSize = 256 << 20
    thread.start()
}
