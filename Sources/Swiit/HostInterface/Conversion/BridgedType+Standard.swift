import Foundation

extension Value: BridgedType {
    public static var scriptType: ScriptType { .any }
    public init(_ swiitValue: Value) { self = swiitValue }
    public var value: Value { self }
}

extension Int: BridgedType {
    public static var scriptType: ScriptType { .int }
    public init(_ swiitValue: Value) throws {
        guard case .int(let value) = swiitValue.storage else {
            throw SwiitError.expected("Int", swiitValue)
        }
        self = value
    }
    public var value: Value { .int(self) }
}

extension Double: BridgedType {
    public static var scriptType: ScriptType { .double }
    public init(_ swiitValue: Value) throws {
        switch swiitValue.storage {
        case .double(let value): self = value
        case .int(let value): self = Double(value)
        default: throw SwiitError.expected("Double", swiitValue)
        }
    }
    public var value: Value { .double(self) }
}

extension String: BridgedType {
    public static var scriptType: ScriptType { .string }
    public init(_ swiitValue: Value) throws {
        guard case .string(let value) = swiitValue.storage else {
            throw SwiitError.expected("String", swiitValue)
        }
        self = value
    }
    public var value: Value { .string(self) }
}

extension Bool: BridgedType {
    public static var scriptType: ScriptType { .bool }
    public init(_ swiitValue: Value) throws {
        guard case .bool(let value) = swiitValue.storage else {
            throw SwiitError.expected("Bool", swiitValue)
        }
        self = value
    }
    public var value: Value { .bool(self) }
}

extension Date: BridgedType {
    public static var scriptType: ScriptType { .named("Date") }
    public init(_ swiitValue: Value) throws {
        guard let value = swiitValue.date else { throw SwiitError.expected("Date", swiitValue) }
        self = value
    }
    public var value: Value { .date(self) }
}

extension Array: ValueEnums where Element: BridgedType {}
extension Dictionary: ValueEnums where Key: BridgedType, Value: BridgedType {}
extension Optional: ValueEnums where Wrapped: BridgedType {}

extension Array: BridgedType where Element: BridgedType {
    public static var scriptType: ScriptType { .list(Element.scriptType) }
    static var enumTypes: [Value.EnumCase.Enumeration] { Element.swiitEnums }
    public init(_ swiitValue: Value) throws {
        switch swiitValue.storage {
        case .list(let items): self = try items.map(Element.init(_:))
        // A Swift sequence Swiit holds (a host type's lines).
        case .object(let box as SwiftValue) where box.value is any Sequence:
            self = try SwiftValue.elements(of: box.value).map { try Element(Value(reflecting: $0)) }
        default: throw SwiitError.expected("[\(Element.scriptType)]", swiitValue)
        }
    }
    public var value: Value { .list(map(\.value)) }
}

extension Dictionary: BridgedType where Key: BridgedType, Value: BridgedType {
    public static var scriptType: ScriptType { .dictionary(Key.scriptType, Value.scriptType) }
    static var enumTypes: [Swiit.Value.EnumCase.Enumeration] { Key.swiitEnums + Value.swiitEnums }
    public init(_ swiitValue: Swiit.Value) throws {
        guard case .dictionary(let entries) = swiitValue.storage else {
            throw SwiitError.expected("[\(Key.scriptType): \(Value.scriptType)]", swiitValue)
        }
        self.init(uniqueKeysWithValues: try entries.map { (try Key($0.key), try Value($0.value)) })
    }
    public var value: Swiit.Value {
        .dictionary(
            Swift.Dictionary(map { ($0.key.value, $0.value.value) }, uniquingKeysWith: { $1 })
        )
    }
}

extension Optional: BridgedType where Wrapped: BridgedType {
    public static var scriptType: ScriptType { .optional(Wrapped.scriptType) }
    static var enumTypes: [Value.EnumCase.Enumeration] { Wrapped.swiitEnums }
    public init(_ swiitValue: Value) throws {
        self = swiitValue == .nothing ? nil : try Wrapped(swiitValue)
    }
    public var value: Value { map(\.value) ?? .nothing }
}
