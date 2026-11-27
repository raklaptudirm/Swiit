import Foundation
import SwiftSyntax
import Synchronization

// How a failure of a run becomes a diagnostic: a runtime error, a fatal one, a limit, a stop, or a mistake in types.

extension Diagnostic {
    /// The language's own run-time error, as a diagnostic.
    init(runtime error: RuntimeError) {
        self.init(
            kind: .runtime(
                Failure(
                    thrown: error.thrown.map { .value($0) } ?? .message,
                    origin: error.origin,
                    calls: error.calls
                )
            ),
            message: error.description,
            range: error.range
        )
    }

    /// What any error that came out of a run is, as a diagnostic.
    static func of(_ error: any Error) -> Diagnostic {
        switch error {
        case let diagnostic as Diagnostic: diagnostic
        case let error as TypeError:
            Diagnostic(
                kind: .type,
                message: error.message,
                range: error.spot ?? error.range ?? error.line.map { SourceRange(line: $0) }
            )
        case let error as RuntimeError: Diagnostic(runtime: error)
        case let fatal as FatalError:
            { () -> Diagnostic in
                var diagnostic = Diagnostic(runtime: fatal.error)
                if case .runtime(let failure) = diagnostic.kind {
                    diagnostic.kind = .fatal(failure)
                }
                return diagnostic
            }()
        case let limit as LimitExceeded: Diagnostic(kind: .limit, message: limit.description)
        case is Cancelled: Diagnostic(kind: .cancelled, message: "cancelled")
        case is Interrupted: Diagnostic(kind: .cancelled, message: "interrupted")
        default: Diagnostic.runtime("\(error)", cause: error)
        }
    }
}
