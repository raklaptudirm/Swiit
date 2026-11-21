import Foundation

extension Value: BridgedValue {
    public static var typeExpression: TypeExpression { .any }
    public init(_ swiitValue: Value) { self = swiitValue }
    public var value: Value { self }
}

extension Int: BridgedValue {
    public static var typeExpression: TypeExpression { .int }
    public init(_ swiitValue: Value) throws {
        guard case .int(let value) = swiitValue.storage else {
            throw SwiitError.expected("Int", swiitValue)
        }
        self = value
    }
    public var value: Value { .int(self) }
}

extension Double: BridgedValue {
    public static var typeExpression: TypeExpression { .double }
    public init(_ swiitValue: Value) throws {
        switch swiitValue.storage {
        case .double(let value): self = value
        case .int(let value): self = Double(value)
        default: throw SwiitError.expected("Double", swiitValue)
        }
    }
    public var value: Value { .double(self) }
}

extension String: BridgedValue {
    public static var typeExpression: TypeExpression { .string }
    public init(_ swiitValue: Value) throws {
        guard case .string(let value) = swiitValue.storage else {
            throw SwiitError.expected("String", swiitValue)
        }
        self = value
    }
    public var value: Value { .string(self) }
}

extension Bool: BridgedValue {
    public static var typeExpression: TypeExpression { .bool }
    public init(_ swiitValue: Value) throws {
        guard case .bool(let value) = swiitValue.storage else {
            throw SwiitError.expected("Bool", swiitValue)
        }
        self = value
    }
    public var value: Value { .bool(self) }
}

extension Date: BridgedValue {
    public static var typeExpression: TypeExpression { .named("Date") }
    public init(_ swiitValue: Value) throws {
        guard let value = swiitValue.date else { throw SwiitError.expected("Date", swiitValue) }
        self = value
    }
    public var value: Value { .date(self) }
}

extension Array: ValueEnums where Element: BridgedValue {}
extension Dictionary: ValueEnums where Key: BridgedValue, Value: BridgedValue {}
extension Optional: ValueEnums where Wrapped: BridgedValue {}

extension Array: BridgedValue where Element: BridgedValue {
    public static var typeExpression: TypeExpression { .list(Element.typeExpression) }
    static var enumTypes: [Value.EnumCase.Enumeration] { Element.swiitEnums }
    public init(_ swiitValue: Value) throws {
        switch swiitValue.storage {
        case .list(let items): self = try items.map(Element.init(_:))
        // A Swift sequence Swiit holds (a host type's lines).
        case .object(let box as SwiftValue) where box.value is any Sequence:
            self = try SwiftValue.elements(of: box.value).map { try Element(Value(reflecting: $0)) }
        default: throw SwiitError.expected("[\(Element.typeExpression)]", swiitValue)
        }
    }
    public var value: Value { .list(map(\.value)) }
}

extension Dictionary: BridgedValue where Key: BridgedValue, Value: BridgedValue {
    public static var typeExpression: TypeExpression {
        .dictionary(Key.typeExpression, Value.typeExpression)
    }
    static var enumTypes: [Swiit.Value.EnumCase.Enumeration] { Key.swiitEnums + Value.swiitEnums }
    public init(_ swiitValue: Swiit.Value) throws {
        guard case .dictionary(let entries) = swiitValue.storage else {
            throw SwiitError.expected(
                "[\(Key.typeExpression): \(Value.typeExpression)]",
                swiitValue
            )
        }
        self.init(uniqueKeysWithValues: try entries.map { (try Key($0.key), try Value($0.value)) })
    }
    public var value: Swiit.Value {
        .dictionary(
            Swift.Dictionary(map { ($0.key.value, $0.value.value) }, uniquingKeysWith: { $1 })
        )
    }
}

extension Optional: BridgedValue where Wrapped: BridgedValue {
    public static var typeExpression: TypeExpression { .optional(Wrapped.typeExpression) }
    static var enumTypes: [Value.EnumCase.Enumeration] { Wrapped.swiitEnums }
    public init(_ swiitValue: Value) throws {
        self = swiitValue == .nothing ? nil : try Wrapped(swiitValue)
    }
    public var value: Value { map(\.value) ?? .nothing }
}
