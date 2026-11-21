import Foundation

// safe: its state is touched only holding the interpreter lock
/// A Swift value Swiit has no form of its own for, like a `Substring`, a
/// `Character` or a `URL`, kept as it is. Its type is its Swift type, to
/// the checker and to you; its members are bridged (see
/// Docs/swift-interop.md). It compares, hashes and sorts as the Swift
/// value does, when its type can.
final class SwiftValue: LanguageObject, @unchecked Sendable {
    let value: Any
    /// Its Swift type, as Swiit writes it: `Substring`.
    let typeName: String

    // What it can do as a Swift value (hash, sort, encode) is found out when asked, not kept:
    // anything kept would be another reference to a collection inside it, and a collection with two
    // can't be changed in place (a Set would be copied whole by every `insert`).
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
    func json() throws -> String? {
        // As Swift encodes it, if it can: a FileSize is its byte count.
        guard let encodable = value as? any Encodable else { return nil }
        // A date as ISO 8601 text, not Swift's number of seconds.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(AnyEncodable(value: encodable)), as: UTF8.self)
    }

    /// The elements of a Swift sequence a value holds, in order; none if it is not one.
    static func elements(of value: Any) -> [Any] {
        func all<S: Sequence>(_ sequence: S) -> [Any] { sequence.map { $0 as Any } }
        guard let sequence = value as? any Sequence else { return [] }
        return all(sequence)
    }

    /// Hashes and sorts as the Swift value does whenever it can, found out
    /// when it's boxed, so a value boxed from generic code (a sequence's
    /// elements) compares as one boxed where its type is known.
    static func make<T>(_ value: T, as typeName: String) -> Value {
        .object(SwiftValue(value, typeName: typeName))
    }

    private static func lessThan<C: Comparable>(_ value: C, _ other: Any) -> Bool {
        (other as? C).map { value < $0 } ?? false
    }

    /// The Swift value in `value`, which must be one of type `T`.
    static func unbox<T>(_ type: T.Type, _ value: Value) throws -> T {
        if case .object(let box as SwiftValue) = value.storage, let unboxed = box.value as? T {
            return unboxed
        }
        // A host's own object is held as it is.
        if case .object(let object) = value.storage, let held = object as? T { return held }
        // A Character is held as the one-letter String it is, where Swiit makes it (iterating a
        // String).
        if case .string(let text) = value.storage, text.count == 1, let character = text.first as? T
        {
            return character
        }
        throw SwiitError("expected \(T.self), not \(value.bridgeTypeName)")
    }

    /// Whether it sorts before `other`, if its type is Comparable.
    func isLess(than other: SwiftValue) -> Bool? {
        guard let comparable = value as? any Comparable else { return nil }
        return SwiftValue.lessThan(comparable, other.value)
    }

    private static func equal<E: Equatable>(_ value: E, _ other: Any) -> Bool {
        (other as? E).map { value == $0 } ?? false
    }

    /// Whether it equals `other` as Swift says, when its type is `Equatable` and neither
    /// `Hashable` nor a class (a `TaskPriority`). Nil for the rest, which are compared by
    /// `objectIdentity`.
    func isEqual(to other: SwiftValue) -> Bool? {
        guard !(value is any Hashable), !(type(of: value) is AnyObject.Type),
            let equatable = value as? any Equatable
        else { return nil }
        return SwiftValue.equal(equatable, other.value)
    }

    func equals(_ other: any LanguageObject) -> Bool? {
        (other as? SwiftValue).flatMap { isEqual(to: $0) }
    }

    /// What equality and hashing go by: the value, when it is `Hashable`; the instance, for a class;
    /// the Swift type, for an `Equatable` value (which `isEqual(to:)` tells apart); else this box.
    var objectIdentity: AnyHashable {
        if let hashable = value as? any Hashable { return AnyHashable(hashable) }
        if type(of: value) is AnyObject.Type {
            return AnyHashable(ObjectIdentifier(value as AnyObject))
        }
        if value is any Equatable { return AnyHashable(typeName) }
        return AnyHashable(ObjectIdentifier(self))
    }
    /// A held Swift value has the members registered for its type and no others.
    var memberNames: [String] { [] }
    func member(_ name: String) -> Value? { nil }
    var description: String {
        registered("description") ?? String(describing: value)
    }
    var debugDescription: String {
        registered("debugDescription") ?? String(reflecting: value)
    }

    private func registered(_ property: String) -> String? {
        guard
            let member = Bridge.types[typeName]?.lowered
                .first(where: {
                    $0.name == property && !$0.isStatic && $0.kind == .property
                }),
            let read = member.plain,
            case .string(let text)? = (try? read(["self": .object(self)]))?.storage
        else { return nil }
        return text
    }
}
