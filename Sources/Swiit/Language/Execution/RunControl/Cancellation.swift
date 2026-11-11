import Foundation
import SwiftSyntax
import Synchronization

// Asking a run to stop, from any thread.

extension Interpreter {
    /// A request to stop, from any thread.
    /// A request to stop a task, which a host can ask about before it waits.
    public final class Cancellation: @unchecked Sendable {  // safe: the state is in a `Mutex`; the flag is a word, below
        private struct State {
            var isRequested = false
            /// What wakes the waits going on now, so a request ends them early.
            var wakers: [Int: @Sendable () -> Void] = [:]
            var nextWaker = 0
        }

        private let state = Mutex(State())
        /// What `isSet` reads without the lock, which every step of every script asks. It is a word
        /// written under the lock and read by whoever is running: a stale read only delays the stop by
        /// a step, and a load of a word is atomic where this runs (arm64 and x86-64), as the SIGINT
        /// flag in the host's spawn code is.
        nonisolated(unsafe) private var flag: UnsafeMutablePointer<Int32> = {  // safe: a word read and written atomically, as the doc above says
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

/// Whether the task running an `async` evaluation has been cancelled, which the thread asks as it
/// starts.
final class CancelFlag: Sendable {
    private let value = Mutex(false)
    var isSet: Bool { value.withLock { $0 } }
    func set() { value.withLock { $0 = true } }
}
