import Foundation

/// A Swift value Swish has no form of its own for, like a `Substring`, a
/// `Character` or a `URL`, kept as it is. Its type is its Swift type, to
/// the checker and to you; its members are bridged (see
/// Docs/Design/swift-interop.md). It compares, hashes and sorts as the Swift
/// value does, when its type can.
public final class SwiftValue: SwiitObject, @unchecked Sendable {
    public let value: Any
    /// Its Swift type, as Swish writes it: `Substring`.
    public let typeName: String
    private let hashable: AnyHashable?
    private let lessThan: ((Any) -> Bool)?
    private let encode: (() throws -> String)?

    private init(_ value: Any, typeName: String, hashable: AnyHashable?, lessThan: ((Any) -> Bool)?) {
        self.value = value
        self.typeName = typeName
        self.hashable = hashable
        self.lessThan = lessThan
        // As Swift encodes it, if it can: a FileSize is its byte count.
        encode = (value as? any Encodable).map { encodable in
            {
                // A date as ISO 8601 text, not Swift's number of seconds.
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                return String(decoding: try encoder.encode(AnyEncodable(value: encodable)), as: UTF8.self)
            }
        }
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
        try encode?()
    }

    /// Hashes and sorts as the Swift value does whenever it can, found out
    /// when it's boxed, so a value boxed from generic code (a sequence's
    /// elements) compares as one boxed where its type is known.
    public static func make<T>(_ value: T, as typeName: String) -> Value {
        .object(SwiftValue(value, typeName: typeName, hashable: (value as? any Hashable).map { AnyHashable($0) },
                           lessThan: (value as? any Comparable).map { lessThan($0) }))
    }

    private static func lessThan<C: Comparable>(_ value: C) -> (Any) -> Bool {
        { other in (other as? C).map { value < $0 } ?? false }
    }

    public static func make<T: Hashable>(_ value: T, as typeName: String) -> Value {
        .object(SwiftValue(value, typeName: typeName, hashable: AnyHashable(value), lessThan: nil))
    }

    public static func make<T: Hashable & Comparable>(_ value: T, as typeName: String) -> Value {
        .object(SwiftValue(value, typeName: typeName, hashable: AnyHashable(value), lessThan: { other in
            (other as? T).map { value < $0 } ?? false
        }))
    }

    /// The Swift value in `value`, which must be one of type `T`.
    public static func unbox<T>(_ type: T.Type, _ value: Value) throws -> T {
        if case .object(let box as SwiftValue) = value, let unboxed = box.value as? T { return unboxed }
        throw SwiitError("expected \(T.self), not \(value.typeName)")
    }

    /// Whether it sorts before `other`, if its type is Comparable.
    public func isLess(than other: SwiftValue) -> Bool? {
        lessThan.map { $0(other.value) }
    }

    public var identity: AnyHashable { hashable ?? AnyHashable(ObjectIdentifier(self)) }
    public var memberNames: [String] { [] }
    public func member(_ name: String) -> Value? { nil }
    public var fields: Record? { nil }
    public var description: String { (value as? any SwiitDisplayed)?.swiitDescription ?? String(describing: value) }
    /// What a table shows of it: its description, unless the type says shorter.
    public var cell: String { (value as? any SwiitDisplayed)?.swiitCell ?? description }
    public var debugDescription: String { (value as? any SwiitDisplayed)?.swiitDebugDescription ?? String(reflecting: value) }
}
