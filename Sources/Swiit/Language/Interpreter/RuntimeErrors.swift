import Foundation
import SwiitKit

@_spi(Host) public struct RuntimeError: Error, CustomStringConvertible {
    @_spi(Host) public let description: String
    /// The status the failure gives: a failed command's own, for `$(…)`.
    @_spi(Host) public var status: Int32 = 1
    /// What `catch` binds when the thrower has more to say than a message: the
    /// shell's failed command carries its status and text.
    @_spi(Host) public var thrown: Value?

    @_spi(Host) public init(_ description: String, status: Int32 = 1, thrown: Value? = nil) {
        self.description = description
        self.status = status
        self.thrown = thrown
    }

    /// What `catch` binds. As in Swift it is an `Error`, which tells its
    /// `localizedDescription`; to get at more, cast it (`error as? T`).
    @_spi(Host) public var value: Value {
        thrown ?? .record(Record(["localizedDescription": .string(description)], typeName: "Error"))
    }
}

/// A runtime error under `try!`: it stops a script, not just the line.
@_spi(Host) public struct FatalError: Error {
    @_spi(Host) public let error: RuntimeError

    @_spi(Host) public init(error: RuntimeError) {
        self.error = error
    }
}

/// ^C while the shell itself was running code.
/// ^C, or in a script SIGTERM or SIGHUP: stops what's running.
@_spi(Host) public struct Interrupted: Error {
    @_spi(Host) public var reason: StopReason

    @_spi(Host) public init(reason: StopReason) {
        self.reason = reason
    }
}

/// Non-local exits, thrown up to the loop or call that handles them. The
/// parser guarantees each one has a handler.
@_spi(Host) public enum ControlFlow: Error {
    case returned(Value)
    case breakLoop
    case continueLoop
    case fallthroughCase
}

/// A runtime error that has been reported already; it still fails the input.
@_spi(Host) public struct AlreadyReported: Error {
    @_spi(Host) public let error: RuntimeError

    @_spi(Host) public init(error: RuntimeError) { self.error = error }
}
