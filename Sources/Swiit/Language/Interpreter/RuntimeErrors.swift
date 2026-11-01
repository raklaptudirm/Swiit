import Foundation
import SwiftSyntax

struct RuntimeError: Error, CustomStringConvertible {
    let description: String
    /// Who raised it: the language, or a host function with an error of its own to read back.
    var origin: Diagnostic.Failure.Origin = .language
    /// What `catch` binds when the thrower has more to say than a message: the
    /// host's failed command carries its status and text.
    var thrown: Value?
    /// The statement it happened in, once the run knows it.
    var range: SourceRange?
    /// The functions it unwound out of, innermost first, and where each was called.
    var calls: [Call] = []

    typealias Call = Diagnostic.Call

    init(
        _ description: String,
        origin: Diagnostic.Failure.Origin = .language,
        thrown: Value? = nil
    ) {
        self.description = description
        self.origin = origin
        self.thrown = thrown
    }

    /// What `catch` binds. As in Swift it is an `Error`, which tells its
    /// `localizedDescription`; to get at more, cast it (`error as? T`).
    var value: Value {
        thrown
            ?? Value(
                record:
                    Value.Record(["localizedDescription": .string(description)], typeName: "Error")
            )
    }
}

/// An error that ends the run, which a script's `catch` does not see: a runtime error under `try!`,
/// or a host function ending the script.
struct FatalError: Error {
    var error: RuntimeError

    init(error: RuntimeError) {
        self.error = error
    }
}

/// ^C while the host itself was running code.
/// ^C, or in a script SIGTERM or SIGHUP: stops what's running.
struct Interrupted: Error, Unwinding {
    var reason: StopReason

    init(reason: StopReason) {
        self.reason = reason
    }
}

/// Non-local exits, thrown up to the loop or call that handles them. The
/// parser guarantees each one has a handler.
enum ControlFlow: Error {
    case returned(Value)
    /// `break` or `continue`, with the label of the loop it names, if it does.
    case breakLoop(String?)
    case continueLoop(String?)
    case fallthroughCase
}

/// An error that passes a script's `catch` and ends the run: what the language raises to stop it.
protocol Unwinding: Error {}
