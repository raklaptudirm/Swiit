import Foundation
import SwiftSyntax
import Synchronization

// What bounds a run, and what stops a run that crosses a bound.

extension Interpreter {
    /// What bounds a run. Each is checked as the script runs; a script that hits
    /// one stops with a `.limit` diagnostic, which it can't catch. Memory isn't
    /// limited: a script that builds a huge list is bounded only by steps and time.
    public struct Limits: Sendable {
        /// Statements and calls. Nil is no limit.
        public var maxSteps: Int?
        /// Nested Swiit function calls.
        public var maxCallDepth: Int
        public var timeLimit: Duration?
        /// Bytes written to the host's output and error.
        public var maxOutputBytes: Int?
        /// Tasks running at once, each on a thread of its own.
        public var maxTasks: Int

        public init(
            maxSteps: Int? = nil,
            maxCallDepth: Int = 10_000,
            timeLimit: Duration? = nil,
            maxOutputBytes: Int? = nil,
            maxTasks: Int = 256
        ) {
            self.maxSteps = maxSteps
            self.maxCallDepth = maxCallDepth
            self.timeLimit = timeLimit
            self.maxOutputBytes = maxOutputBytes
            self.maxTasks = maxTasks
        }
    }
}

struct LimitExceeded: Error, Unwinding, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Bytes written so far, for the output limit.
final class OutputCounter: Sendable {
    private let count = Mutex(0)

    init() {}

    var written: Int { count.withLock { $0 } }
    func add(_ bytes: Int) { count.withLock { $0 += bytes } }
    func reset() { count.withLock { $0 = 0 } }
}
