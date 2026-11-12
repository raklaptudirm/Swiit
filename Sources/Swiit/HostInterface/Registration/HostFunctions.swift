import Foundation
import Synchronization

// MARK: What a host exports

extension Symbol.Parameter {
    /// As the language's own builtins describe one.
    init(
        label: String?,
        name: String,
        type: ScriptType,
        variadic: Bool = false,
        documentation: String? = nil,
        defaultValue: Value? = nil,
        showsByType: Bool = false
    ) {
        self.init(
            label: label,
            name: name,
            type: type,
            arity: variadic ? .variadic : defaultValue.map { .defaulted(.value($0)) } ?? .required,
            documentation: documentation
        )
        self.showsByType = showsByType
    }
}

extension Symbol.Parameter {
    /// A parameter of a Swift type: `Symbol.Parameter(name: "count", type: Int.self)`.
    public init<T: ScriptConvertible>(
        label: String? = nil,
        name: String,
        type: T.Type,
        arity: Arity = .required
    ) {
        self.init(label: label, name: name, type: ScriptType(type), arity: arity)
    }
}

// safe: its state is touched only holding the interpreter lock
/// A host's function or method as a value, as `repo.log` gives it. The
/// host calls it like any other function.
final class NativeFunction: Callable, @unchecked Sendable {
    let function: HostSymbol

    init(_ function: HostSymbol) {
        self.function = function
    }

    var description: String {
        "(Function)"
    }
}

/// A failure in converting between Swift and Swiit values, or one a host's function
/// throws to report a problem the way the host's own errors read.
struct SwiitError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

// MARK: Converting values

/// A Swift type that can be a parameter: the host hands it a `Value`, and
/// it says what type the host should check for.
///
/// It is also how a type is held as it is: a type that is `Sendable` and conforms with no more than
/// `extension URL: ScriptConvertible {}` is held under its Swift name, by value if it is `Hashable`
/// and by identity if it is a class, and its registered members are its members (`HostType.Builder`). A
/// type that answers for members it only knows at run time, like a parsed object's keys, says them.
public protocol ScriptConvertible {
    static var scriptType: ScriptType { get }
    init(_ swiitValue: Value) throws
    var value: Value { get }
    /// The names of the members it answers for at run time, in order, or nil, the default, if all
    /// its members are registered. A type with names is laid out as a record is, in a table and in
    /// JSON.
    var memberNames: [String]? { get }
    /// A member answered at run time, after the registered ones; nil if there is none.
    func member(_ name: String) -> Value?
}

extension ScriptConvertible {
    public var memberNames: [String]? { nil }
    public func member(_ name: String) -> Value? { nil }
}

/// A type that names enums in its `scriptType`, which scripts learn by name: containers hold their
/// elements'. An SPI refinement, because a requirement only the module can see cannot be satisfied
/// by a conformance outside it.
protocol ValueEnums { static var enumTypes: [Value.EnumCase.Enumeration] { get } }

extension ScriptConvertible {
    /// The enums `scriptType` names.
    static var swiitEnums: [Value.EnumCase.Enumeration] {
        if let carrier = self as? any ValueEnums.Type { return carrier.enumTypes }
        if let enumeration = self as? any CaseIterable.Type {
            return [Value.EnumCase.Enumeration.of(enumeration)]
        }
        return []
    }
}

extension Value: ScriptConvertible {
    public static var scriptType: ScriptType { .any }
    public init(_ swiitValue: Value) { self = swiitValue }
    public var value: Value { self }
}

extension Int: ScriptConvertible {
    public static var scriptType: ScriptType { .int }
    public init(_ swiitValue: Value) throws {
        guard case .int(let value) = swiitValue.storage else {
            throw SwiitError.expected("Int", swiitValue)
        }
        self = value
    }
    public var value: Value { .int(self) }
}

extension Double: ScriptConvertible {
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

extension String: ScriptConvertible {
    public static var scriptType: ScriptType { .string }
    public init(_ swiitValue: Value) throws {
        guard case .string(let value) = swiitValue.storage else {
            throw SwiitError.expected("String", swiitValue)
        }
        self = value
    }
    public var value: Value { .string(self) }
}

extension Bool: ScriptConvertible {
    public static var scriptType: ScriptType { .bool }
    public init(_ swiitValue: Value) throws {
        guard case .bool(let value) = swiitValue.storage else {
            throw SwiitError.expected("Bool", swiitValue)
        }
        self = value
    }
    public var value: Value { .bool(self) }
}

extension Date: ScriptConvertible {
    public static var scriptType: ScriptType { .named("Date") }
    public init(_ swiitValue: Value) throws {
        guard let value = swiitValue.date else { throw SwiitError.expected("Date", swiitValue) }
        self = value
    }
    public var value: Value { .date(self) }
}

extension Array: ValueEnums where Element: ScriptConvertible {}
extension Dictionary: ValueEnums where Key: ScriptConvertible, Value: ScriptConvertible {}
extension Optional: ValueEnums where Wrapped: ScriptConvertible {}

extension Array: ScriptConvertible where Element: ScriptConvertible {
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

extension Dictionary: ScriptConvertible where Key: ScriptConvertible, Value: ScriptConvertible {
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

extension Optional: ScriptConvertible where Wrapped: ScriptConvertible {
    public static var scriptType: ScriptType { .optional(Wrapped.scriptType) }
    static var enumTypes: [Value.EnumCase.Enumeration] { Wrapped.swiitEnums }
    public init(_ swiitValue: Value) throws {
        self = swiitValue == .nothing ? nil : try Wrapped(swiitValue)
    }
    public var value: Value { map(\.value) ?? .nothing }
}

extension SwiitError {
    static func expected(_ type: String, _ value: Value) -> SwiitError {
        SwiitError("expected \(type), not \(value.bridgeTypeName)")
    }
}

extension Value {
    /// The type name a conversion error uses.
    var bridgeTypeName: String {
        switch self.storage {
        case .nothing: "nil"
        case .bool: "Bool"
        case .int: "Int"
        case .double: "Double"
        case .string: "String"
        case .list: "List"
        case .tuple: "Tuple"
        case .structure(let structure): structure.typeName
        case .dictionary: "Dictionary"
        case .enumValue(let value): value.type.name
        case .object(let object): object.typeName
        case .function: "Function"
        }
    }

    /// A function's result, whatever Swift type it has: a convertible
    /// value, an exported object, `Encodable` data as records, or nothing.
    init(returning result: Any) throws {
        switch result {
        case is Void: self = .nothing
        case let value as any ScriptConvertible: self = value.value
        case let data as any Encodable: self = try ValueEncoder().encode(data)
        default: throw SwiitError("can't return a \(type(of: result)) to Swiit; make it Encodable")
        }
    }
}

/// What the host checks a parameter's arguments against.
func swiitParameterType<T: ScriptConvertible>(_ type: T.Type) -> ScriptType { T.scriptType }
func swiitParameterEnums<T: ScriptConvertible>(_ type: T.Type) -> [Value.EnumCase.Enumeration] {
    T.swiitEnums
}

/// What a function returns, for signatures and help.
func swiitReturnType(_ type: Any.Type) -> ScriptType {
    (type as? any ScriptConvertible.Type)?.scriptType ?? .any
}

/// An argument the macro-generated code converts: a clear message naming
/// the function and parameter when it doesn't fit.
func swiitArgument<T: ScriptConvertible>(
    _ arguments: Arguments,
    _ name: String,
    of function: String,
    as type: T.Type = T.self
) throws -> T {
    do {
        return try T(arguments[name] ?? .nothing)
    } catch let error as SwiitError {
        throw SwiitError("\(function): \(name): \(error)")
    }
}

/// A Swift enum without associated values is an enum scripts can use (as a parameter, `volume .high`
/// or `volume(.high)`, a result, and in `switch`) by saying it converts:
///
///     public enum Level: String, CaseIterable, ScriptConvertible { case low, high }
///
/// The host learns it by name from the functions that take it.
extension ScriptConvertible where Self: CaseIterable & Hashable & Sendable {
    public static var scriptType: ScriptType {
        .named(Value.EnumCase.Enumeration.of(Self.self).name)
    }

    public init(_ swiitValue: Value) throws {
        guard case .enumValue(let value) = swiitValue.storage,
            value.type === Value.EnumCase.Enumeration.of(Self.self),
            let found = Self.allCases.first(where: { String(describing: $0) == value.name })
        else {
            throw SwiitError.expected(Value.EnumCase.Enumeration.of(Self.self).name, swiitValue)
        }
        self = found
    }

    public var value: Value {
        .enumValue(
            Value.EnumCase(
                type: Value.EnumCase.Enumeration.of(Self.self),
                name: String(describing: self)
            )
        )
    }
}

extension Value.EnumCase.Enumeration {
    /// The enum a Swift enum is, with its cases and raw values as Swiit sees them; one instance
    /// per type, so values compare equal across calls.
    static func of<E: CaseIterable>(_ type: E.Type) -> Value.EnumCase.Enumeration {
        EnumRegistry.shared.type(for: type) {
            Value.EnumCase.Enumeration(
                name: String(describing: type),
                cases: type.allCases.map { value in
                    let raw = (value as? any RawRepresentable)?.rawValue
                    return Value.EnumCase.Enumeration.Case(
                        name: String(describing: value),
                        rawValue: raw.flatMap { raw in
                            switch raw {
                            case let int as Int: .int(int)
                            case let string as String: .string(string)
                            default: nil
                            }
                        }
                    )
                },
                conformances: type is any Comparable.Type ? ["Comparable"] : []
            )
        }
    }
}

/// Each Swift enum's `EnumType`, made once.
final class EnumRegistry: Sendable {
    static let shared = EnumRegistry()
    private let types = Mutex<[ObjectIdentifier: Value.EnumCase.Enumeration]>([:])

    func type(
        for key: Any.Type,
        _ make: () -> Value.EnumCase.Enumeration
    ) -> Value.EnumCase.Enumeration {
        types.withLock { types in
            if let type = types[ObjectIdentifier(key)] { return type }
            let type = make()
            types[ObjectIdentifier(key)] = type
            return type
        }
    }
}
