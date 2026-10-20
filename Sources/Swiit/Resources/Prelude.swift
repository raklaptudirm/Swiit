// The builtins' types and signatures, written in Swiit and read when the host starts. The checker works from these;
// the bodies are in Swift, found by name. Doc comments are what help shows. Not compiled: embedded in the target.

/// What `catch` binds: any error, which tells what went wrong. Cast it to
/// get at more, as in Swift: `if let failure = error as? CommandFailure`.
struct Error {
    let localizedDescription: String
}

/// What has no values: a `Task<Int, Never>` can't fail.
enum Never {}

/// A value, or the error that kept it from being made.
enum Result<Success, Failure: Error> {
    case success(Success)
    case failure(Failure)

    init(catching body: () throws -> Success) {
        do { self = Result.success(try body()) } catch { self = Result.failure(error) }
    }

    /// The value, or throws the error.
    func get() throws -> Success {
        switch self {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    func map<NewSuccess>(_ transform: (Success) -> NewSuccess) -> Result<NewSuccess, Failure> {
        switch self {
        case .success(let value): return .success(transform(value))
        case .failure(let error): return .failure(error)
        }
    }

    func mapError<NewFailure: Error>(_ transform: (Failure) -> NewFailure) -> Result<Success, NewFailure> {
        switch self {
        case .success(let value): return .success(value)
        case .failure(let error): return .failure(transform(error))
        }
    }

    func flatMap<NewSuccess>(_ transform: (Success) -> Result<NewSuccess, Failure>) -> Result<NewSuccess, Failure> {
        switch self {
        case .success(let value): return transform(value)
        case .failure(let error): return .failure(error)
        }
    }
}

/// What `Mirror(reflecting:)` shows of a value: its stored properties, in order.
struct Mirror {
    let children: [(label: String?, value: Any)]

    init(reflecting subject: Any) {
        children = __mirrorChildren(subject)
    }
}

/// The type of no value, for `Void.self` where a type is passed.
enum Void {}

/// What a task that was asked to stop throws, from `Task.checkCancellation()`
/// or `Task.sleep`.
struct CancellationError: Error {
    let localizedDescription: String
}


extension Sequence {
    /// Each item with its position, as pairs: Swift's lazy `EnumeratedSequence` is held as the array it would give.
    func enumerated() -> [(offset: Int, element: Element)] {
        var pairs: [(offset: Int, element: Element)] = []
        var position = 0
        for element in self {
            pairs.append((offset: position, element: element))
            position += 1
        }
        return pairs
    }
}
