import Foundation
import SwiftSyntax
import Synchronization

// Asking a run to stop, from any thread.

extension Interpreter {
    // safe: the state is in a `Mutex`; the flag is a word, below
    /// A request to stop, from any thread.
    /// A request to stop a task, which a host can ask about before it waits.
    public final class Cancellation: @unchecked Sendable {
        private struct State {
            var isRequested = false
            /// What wakes the waits going on now, so a request ends them early.
            var wakers: [Int: @Sendable () -> Void] = [:]
            var nextWaker = 0
        }

        private let state = Mutex(State())
        // safe: a word read and written atomically, as the doc above says
        /// What `isSet` reads without the lock, which every step of every script asks. It is a word
        /// written under the lock and read by whoever is running: a stale read only delays the stop by
        /// a step, and a load of a word is atomic where this runs (arm64 and x86-64), as the SIGINT
        /// flag in the host's spawn code is.
        nonisolated(unsafe) private var flag: UnsafeMutablePointer<Int32> = {
            let pointer = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
            pointer.initialize(to: 0)
            return pointer
        }()

        deinit { flag.deallocate() }

        init() {}

        public var isSet: Bool { readFlag() != 0 }

        /// Not inlined, so that a loop asking again reads the word again.
        @inline(never)
        private func readFlag() -> Int32 { flag.pointee }

        /// Asks for the stop, and wakes what is waiting.
        func request() {
            let wake = state.withLock { state -> [@Sendable () -> Void] in
                state.isRequested = true
                flag.pointee = 1
                return Array(state.wakers.values)
            }
            wake.forEach { $0() }
        }

        func clear() {
            state.withLock { state in
                state.isRequested = false; flag.pointee = 0
            }
        }

        /// Calls `wake` when the stop is asked for (now, if it was already), until
        /// `remove` is given what this gives.
        func onRequest(_ wake: @escaping @Sendable () -> Void) -> Int {
            let (token, already) = state.withLock { state -> (Int, Bool) in
                state.nextWaker += 1
                state.wakers[state.nextWaker] = wake
                return (state.nextWaker, state.isRequested)
            }
            if already { wake() }
            return token
        }

        func remove(_ token: Int) {
            state.withLock { _ = $0.wakers.removeValue(forKey: token) }
        }
    }
}

struct Cancelled: Error, Unwinding {}

/// A request to stop one run, made before the run has begun or while it goes on: the task running
/// an `async` evaluation is cancelled from outside, and the run is made on a thread of its own.
final class CancelFlag: Sendable {
    private struct State {
        var isSet = false
        var target: Interpreter.Cancellation?
    }

    private let state = Mutex(State())

    /// Asks the run to stop: now if it has begun, and as it begins if it has not.
    func set() {
        let target = state.withLock { state -> Interpreter.Cancellation? in
            state.isSet = true
            return state.target
        }
        target?.request()
    }

    /// Ties the flag to the run it asks to stop, which has begun.
    func link(_ cancellation: Interpreter.Cancellation) {
        let already = state.withLock { state -> Bool in
            state.target = cancellation
            return state.isSet
        }
        if already { cancellation.request() }
    }
}
