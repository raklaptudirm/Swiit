import Foundation

/// How a host function fails so a script can see it: the message is what is reported, and a script's `catch` can bind it.
/// Anything else a host function throws that is not `Unwinding` is reported as `name: error`, and caught the same way.
public struct ScriptError: Error, CustomStringConvertible, Sendable {
    public var message: String
    /// The status a host that has statuses (a host's) gives the failure.
    public var status: Int32
    /// What `catch` binds when there is more to say than the message: a struct of the failure's fields.
    public var value: Value?
    /// The host has told the person already; the run still fails, but the host reports nothing more.
    public var isReported: Bool

    public init(_ message: String, status: Int32 = 1, value: Value? = nil, isReported: Bool = false) {
        self.message = message
        self.status = status
        self.value = value
        self.isReported = isReported
    }

    public var description: String { message }
}

/// An error a host function throws to end the run, which a script cannot catch: its `catch` and `try?` let it go by, its
/// `defer`s run, and it reaches the host as the `cause` of the diagnostic `evaluate` throws. A host's `exit` and a job
/// stopping are such.
public protocol Unwinding: Error {}
