import Foundation

/// A Swift value Swiit has no form of its own for, like a `Substring`, a
/// `Character` or a `URL`, kept as it is. Its type is its Swift type, to
/// the checker and to you; its members are bridged (see
/// Docs/swift-interop.md). It compares, hashes and sorts as the Swift
/// value does, when its type can.
@_spi(Layer) public final class SwiftValue: ObjectDetails, @unchecked Sendable { // safe: its state is touched only holding the interpreter lock
    public let value: Any
    /// Its Swift type, as Swiit writes it: `Substring`.
    public let typeName: String

    // What it can do as a Swift value (hash, sort, encode) is found out when asked, not kept: anything
    // kept would be another reference to a collection inside it, and a collection with two can't be
    // changed in place (a Set would be copied whole by every `insert`).
    private init(_ value: Any, typeName: String) {
        self.value = value
        self.typeName = typeName
    }

    private struct AnyEncodable: Encodable {
        let value: any Encodable
        // Through a container, which is what applies the encoder's strategy for dates.
        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(value)
        }
    }

    /// Its JSON, if its Swift type is Encodable.
    public func json() throws -> String? {
        // As Swift encodes it, if it can: a FileSize is its byte count.
        guard let encodable = value as? any Encodable else { return nil }
        // A date as ISO 8601 text, not Swift's number of seconds.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(AnyEncodable(value: encodable)), as: UTF8.self)
    }

    /// The elements of a Swift sequence a value holds, in order; none if it is not one.
    public static func elements(of value: Any) -> [Any] {
        func all<S: Sequence>(_ sequence: S) -> [Any] { sequence.map { $0 as Any } }
        guard let sequence = value as? any Sequence else { return [] }
        return all(sequence)
    }

    /// Hashes and sorts as the Swift value does whenever it can, found out
    /// when it's boxed, so a value boxed from generic code (a sequence's
    /// elements) compares as one boxed where its type is known.
    public static func make<T>(_ value: T, as typeName: String) -> Value {
        .object(SwiftValue(value, typeName: typeName))
    }

    private static func lessThan<C: Comparable>(_ value: C, _ other: Any) -> Bool {
        (other as? C).map { value < $0 } ?? false
    }

    /// The Swift value in `value`, which must be one of type `T`.
    public static func unbox<T>(_ type: T.Type, _ value: Value) throws -> T {
        if case .object(let box as SwiftValue) = value, let unboxed = box.value as? T { return unboxed }
        // A host's own object is held as it is.
        if case .object(let object) = value, let held = object as? T { return held }
        // A Character is held as the one-letter String it is, where Swiit makes it (iterating a String).
        if case .string(let text) = value, text.count == 1, let character = text.first as? T { return character }
        throw SwiitError("expected \(T.self), not \(value.bridgeTypeName)")
    }

    /// Whether it sorts before `other`, if its type is Comparable.
    public func isLess(than other: SwiftValue) -> Bool? {
        guard let comparable = value as? any Comparable else { return nil }
        return SwiftValue.lessThan(comparable, other.value)
    }

    public var identity: AnyHashable { (value as? any Hashable).map { AnyHashable($0) } ?? AnyHashable(ObjectIdentifier(self)) }
    public var memberNames: [String] { [] }
    public func member(_ name: String) -> Value? { nil }
    public var fields: Record? { nil }
    public var description: String { (value as? any SwiitDisplayed)?.swiitDescription ?? String(describing: value) }
    /// What a table shows of it: its description, unless the type says shorter.
    public var cell: String { (value as? any SwiitDisplayed)?.swiitCell ?? description }
    public var debugDescription: String { (value as? any SwiitDisplayed)?.swiitDebugDescription ?? String(reflecting: value) }
}

@_spi(Layer) extension SwiftValue: LanguageObject {}
