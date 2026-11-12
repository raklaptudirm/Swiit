import Foundation

extension Value {
    /// What code that bridges a Swift module to scripts calls: the conversions a bridge generator's
    /// output is made of. A Swift value in a script is a ``Value``, and a member written for a Swift
    /// type unwraps its arguments with these and wraps its result.
    public enum Bridging {}
}

extension Value.Bridging {
    /// A Swiit key path (`\.status.code`) as a Swift one over
    /// values: each name a subscript that reads the field, one after another.
    public static func keyPath(_ value: Value) throws -> KeyPath<Value, Value> {
        guard case .function(let keyPath as KeyPathValue) = value.storage else {
            throw SwiitError("expected a key path, not \(value.typeName)")
        }
        return keyPath.path.reduce(\Value.self) { path, name in
            path.appending(path: \Value.[field: name])
        }
    }

    /// Runs `body`, which reads fields through key paths, with fields read as the
    /// host reads them; the first failure (a field that isn't there) is thrown
    /// after it, since a key path can't throw.
    public static func withFieldReader<T>(
        _ interpreter: Interpreter,
        _ body: () throws -> T
    ) throws -> T {
        var failure: Error?
        let saved = FieldAccess.reader
        FieldAccess.reader = { value, name in
            do { return try interpreter.member(name, of: value) } catch {
                failure = failure ?? error
                return .nothing
            }
        }
        defer { FieldAccess.reader = saved }
        let result = try body()
        if let failure { throw failure }
        return result
    }

    /// A case of a Swift enum from a Swiit value: the case of that name, among
    /// all the enum's.
    static func enumCase<T: CaseIterable>(_ type: T.Type, _ value: Value) throws -> T {
        guard case .enumValue(let found) = value.storage,
            let match = T.allCases.first(where: { "\($0)" == found.name })
        else {
            throw SwiitError("expected a \(T.self), not \(value.typeName)")
        }
        return match
    }

    /// A Swift struct as a record, its fields by name, in the order it declares
    /// them and all there: the encoder leaves out a nil, and the declaration says
    /// it's a field. A field of `patches` is read from the Swift value itself and
    /// made what it is declared as.
    static func record<T: Encodable>(
        _ interpreter: Interpreter,
        _ value: T,
        patches: [String: FieldKind] = [:]
    ) -> Value {
        guard let encoded = (try? ValueEncoder().encode(value))?.record else { return .nothing }
        var record = Value.Record(typeName: encoded.typeName)
        for child in Mirror(reflecting: value).children {
            guard let field = child.label else { continue }
            var held: Any? = child.value
            // An optional holds its value, or nothing.
            if let optional = held.map(Mirror.init(reflecting:)), optional.displayStyle == .optional
            {
                held = optional.children.first?.value
            }
            record[field] =
                switch (patches[field], held) {
                case (.enumeration(let type)?, let held?): interpreter.declaredCase(type, "\(held)")
                case (.boxed(let type)?, let held?): SwiftValue.make(held, as: type)
                case (_, .some): encoded[field] ?? .nothing
                default: .nothing
                }
        }
        return Value(record: record)
    }

    /// A list's items, or a Swift sequence's (a host type's lines).
    public static func list(_ value: Value) throws -> [Value] {
        switch value.storage {
        case .list(let items): return items
        default:
            guard let items = Interpreter.items(of: value) else {
                throw SwiitError("expected a list, not \(value.typeName)")
            }
            return Array(items)
        }
    }

    /// A dictionary as Swift's, which is what it holds.
    public static func dictionary(_ value: Value) throws -> [Value: Value] {
        guard case .dictionary(let dictionary) = value.storage else {
            throw SwiitError("expected a dictionary, not \(value.typeName)")
        }
        return dictionary
    }

    /// Swift's dictionary as Swiit's.
    public static func dictionary(_ dictionary: [Value: Value]) -> Value {
        .dictionary(dictionary)
    }

    /// A tuple's elements, by label or position, made into a Swift tuple.
    public static func tuple<T>(
        _ value: Value,
        _ labels: [String?],
        _ make: ([Value]) throws -> T
    ) throws -> T {
        guard let record = value.record, record.typeName == nil, record.count == labels.count
        else {
            throw SwiitError("expected a tuple of \(labels.count), not \(value.typeName)")
        }
        return try make(
            labels.enumerated()
                .map { index, label in
                    label.flatMap { record[$0] } ?? record[record.keys[index]]!
                }
        )
    }

    /// A Swift tuple as Swiit's, from its elements' labels and values.
    public static func tuple<T>(_ tuple: T, _ elements: (T) -> [(String?, Value)]) -> Value {
        var record = Value.Record()
        for (index, (label, value)) in elements(tuple).enumerated() {
            record[label ?? String(index)] = value
        }
        return Value(record: record)
    }

    /// The items of any sequence, for a Swift parameter that takes one: a
    /// String's Characters, a dictionary's (key, value) pairs, or what
    /// `items(of:)` gives.
    public static func sequence(_ value: Value) throws -> [Value] {
        switch value.storage {
        case .string(let text):
            return Array(Interpreter.iterator(text))
        case .dictionary(let dictionary):
            return dictionary.map {
                Value.Bridging.tuple(($0.key, $0.value)) { [("key", $0.0), ("value", $0.1)] }
            }
        default:
            guard let items = Interpreter.items(of: value) else {
                throw SwiitError("expected a sequence, not \(value.typeName)")
            }
            return Array(items)
        }
    }

    /// A range with bounds of a Swift type, from Swiit's range of values.
    public static func range<Bound: Comparable>(
        _ value: Value,
        _ bound: (Value) throws -> Bound
    ) throws -> Range<Bound> {
        let range = try SwiftValue.unbox(Range<Value>.self, value)
        return Range(
            uncheckedBounds: (
                lower: try bound(range.lowerBound), upper: try bound(range.upperBound)
            )
        )
    }

    public static func closedRange<Bound: Comparable>(
        _ value: Value,
        _ bound: (Value) throws -> Bound
    ) throws -> ClosedRange<Bound> {
        let range = try SwiftValue.unbox(ClosedRange<Value>.self, value)
        return ClosedRange(
            uncheckedBounds: (
                lower: try bound(range.lowerBound), upper: try bound(range.upperBound)
            )
        )
    }

    /// A Swift value boxed as Swiit holds it, converted first (a `Set<Int>` to
    /// a `Set<Value>`).
    public static func box<T, Boxed>(
        _ value: T,
        as type: Symbol.ID,
        _ convert: (T) -> Boxed
    ) -> Value {
        SwiftValue.make(convert(value), as: type.name)
    }

    public static func box<T, Boxed: Hashable>(
        _ value: T,
        as type: Symbol.ID,
        _ convert: (T) -> Boxed
    ) -> Value {
        SwiftValue.make(convert(value), as: type.name)
    }

    /// A Swiit function as a Swift closure.
    /// A Swiit value as a Swift optional: nil for nothing, else converted.
    public static func optional<T>(_ value: Value, _ convert: (Value) throws -> T) rethrows -> T? {
        value == .nothing ? nil : try convert(value)
    }

    public static func closure(
        _ interpreter: Interpreter,
        _ function: Value
    ) -> ([Value]) throws -> Value {
        { arguments in try interpreter.call(function, with: arguments) }
    }

    /// Fails with `message` unless `condition` holds: what the glue of a member that would trap
    /// on some arguments checks first.
    public static func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        guard condition else { throw SwiitError(message()) }
    }

    /// Calls a script closure that changes some of its arguments in place (Swift's `inout`): what
    /// it gave back, and the value it left in each argument at `positions`, in that order. A
    /// bridged closure of `(inout Result, Element) -> ()` is
    /// `result = try changing(interpreter, closure, [result, element], at: [0]).changed[0]`.
    public static func changing(
        _ interpreter: Interpreter,
        _ function: Value,
        _ arguments: [Value],
        at positions: [Int]
    ) throws -> (result: Value, changed: [Value]) {
        try interpreter.callChanging(function, arguments, at: positions)
    }

    /// Runs Swift's `operation` to its end, letting other tasks run meanwhile;
    /// cancelling the task cancels it.
    public static func awaiting(
        _ interpreter: Interpreter,
        _ operation: @escaping () async throws -> Value
    ) throws -> Value {
        // Set by the operation's task, read by this thread once it's set.
        final class Outcome: @unchecked Sendable {  // safe: every access holds its own lock
            let operation: () async throws -> Value
            private let condition = NSCondition()
            private var stored: Result<Value, any Error>?
            init(_ operation: @escaping () async throws -> Value) { self.operation = operation }

            func finish(_ result: Result<Value, any Error>) {
                condition.lock()
                stored = result
                condition.broadcast()
                condition.unlock()
            }

            func wait() -> Result<Value, any Error> {
                condition.lock()
                defer { condition.unlock() }
                while stored == nil { condition.wait() }
                return stored!
            }
        }
        let outcome = Outcome(operation)
        let running = Task.detached {
            do { outcome.finish(.success(try await outcome.operation())) } catch {
                outcome.finish(.failure(error))
            }
        }
        let result = interpreter.suspend(wake: { running.cancel() }) { outcome.wait() }
        if case .failure(is CancellationError) = result { throw cancellationError() }
        return try result.get()
    }

    /// A Swiit closure as Swift's `async` one: each call runs it holding the lock,
    /// as the task that passed it, which is waiting in `bridgeAsync` meanwhile.
    public static func asyncClosure(
        _ interpreter: Interpreter,
        _ function: Value
    ) -> ([Value]) async throws -> Value {
        // safe: runs holding the interpreter lock
        nonisolated(unsafe) let interpreter = interpreter
        // safe: runs holding the interpreter lock
        nonisolated(unsafe) let caller = interpreter.task
        let function = function
        return { arguments in
            let arguments = arguments
            return try await withCheckedThrowingContinuation { continuation in
                interpreter.host.startThread {
                    interpreter.lock.acquire()
                    let previous = interpreter.task
                    interpreter.task = caller
                    Waiting.host = interpreter
                    let result = Result { try interpreter.call(function, with: arguments) }
                    interpreter.task = previous
                    interpreter.lock.release()
                    continuation.resume(with: result)
                }
            }
        }
    }

    public static func textLiteral<T: ExpressibleByStringLiteral>(_: T.Type, _ text: String) -> T?
    where T.StringLiteralType == String {
        T(stringLiteral: text)
    }

    public static func textLiteral<T: ExpressibleByExtendedGraphemeClusterLiteral>(
        _: T.Type,
        _ text: String
    ) -> T?
    where T.ExtendedGraphemeClusterLiteralType == Character {
        guard let character = text.first, text.dropFirst().isEmpty else { return nil }
        return T(extendedGraphemeClusterLiteral: character)
    }

    public static func textLiteral<T: ExpressibleByUnicodeScalarLiteral>(
        _: T.Type,
        _ text: String
    ) -> T?
    where T.UnicodeScalarLiteralType == Unicode.Scalar {
        guard let scalar = text.unicodeScalars.first, text.unicodeScalars.dropFirst().isEmpty else {
            return nil
        }
        return T(unicodeScalarLiteral: scalar)
    }
}
