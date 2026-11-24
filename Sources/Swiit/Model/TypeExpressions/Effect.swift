import Foundation

/// Whether a function is `async`, as `throws` says whether it throws
/// (Docs/async.md, "Types and effects"). Only Swift's own `async`: a
/// host's waits are blocking calls, not effects.
enum Effect: Equatable, Sendable {
    case sync
    /// Declared `async`: a call to it is marked with `await`, in an async context.
    case async
}
