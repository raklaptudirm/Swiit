import Foundation

// MARK: What a host exports

/// A function described as data: a name, parameters, a result, and a body. The way to offer commands whose shape is
/// known only at run time. It is checked like any function the script declares.
public struct HostFunction: Sendable {
    public struct Parameter: Sendable {
        public var label: String?
        public var name: String
        public var type: ValueType
        public var defaultValue: Value?
        public var isVariadic: Bool

        public init(label: String? = nil, name: String, type: ValueType = .any, defaultValue: Value? = nil, isVariadic: Bool = false) {
            self.label = label
            self.name = name
            self.type = type
            self.defaultValue = defaultValue
            self.isVariadic = isVariadic
            self.enums = []
        }

        /// The enums its type uses, which the shell learns by name.
        @_spi(Layer) public var enums: [EnumType]
        /// `@Input`: receives what's piped in.
        @_spi(Layer) public var isInput = false
        /// `@Flag("n")`.
        @_spi(Layer) public var shortFlag: Character?
        @_spi(Layer) public var documentation: String?
        /// A default only Swift can compute, like `Date()`: the argument is left out and the function uses its own.
        /// Its source, for `--help`.
        @_spi(Layer) public var defaultSource: String?
        /// What is given is shown as interpolation shows a value.
        @_spi(Layer) public var showsByType = false

        @_spi(Layer) public init(
            label: String?, name: String, type: ValueType, enums: [EnumType] = [], variadic: Bool = false, isInput: Bool = false,
            shortFlag: Character? = nil, documentation: String? = nil, defaultValue: Value? = nil, defaultSource: String? = nil,
            showsByType: Bool = false
        ) {
            self.showsByType = showsByType
            self.label = label
            self.name = name
            self.type = type
            self.enums = enums
            self.isVariadic = variadic
            self.isInput = isInput
            self.shortFlag = shortFlag
            self.documentation = documentation
            self.defaultValue = defaultValue
            self.defaultSource = defaultSource
        }

        @_spi(Layer) public var variadic: Bool { isVariadic }
    }

    public let name: String
    /// The line `help` shows.
    public let summary: String?
    public let parameters: [Parameter]
    public let returns: ValueType?
    /// Declared `throws`: a call to it needs `try`.
    public let isThrowing: Bool
    /// Called with every argument bound, by parameter name, except ones left to a Swift default.
    @_spi(Layer) public let call: @Sendable ([String: Value]) throws -> Value

    /// `body` is called with its arguments in declared order, defaults filled in.
    public init(
        name: String, summary: String? = nil, parameters: [Parameter] = [], returns: ValueType? = nil, isThrowing: Bool = false,
        body: @escaping @Sendable ([Value]) throws -> Value
    ) {
        self.name = name
        self.summary = summary
        self.parameters = parameters
        self.returns = returns
        self.isThrowing = isThrowing
        let defaults = parameters.map { ($0.name, $0.defaultValue) }
        self.call = { arguments in try body(defaults.map { arguments[$0.0] ?? $0.1 ?? .nothing }) }
    }

    /// As the shell's commands are described: a body taking the arguments by name.
    @_spi(Layer) public init(
        name: String, summary: String? = nil, parameters: [Parameter], returnType: ValueType?, isThrowing: Bool = false,
        call: @escaping @Sendable ([String: Value]) throws -> Value
    ) {
        self.name = name
        self.summary = summary
        self.parameters = parameters
        self.returns = returnType
        self.isThrowing = isThrowing
        self.call = call
    }

    @_spi(Layer) public var returnType: ValueType? { returns }
}

/// How a host names a type: a parameter or result of a function it offers, and what `symbols`, `resolveOverload` and
/// `valueType(of:)` speak.
public indirect enum ValueType: Sendable, Hashable, CustomStringConvertible {
    case any, bool, int, double, string, record, function
    /// A type by name, like `Level` or `Date`.
    case named(String)
    case list(ValueType)
    case dictionary(ValueType, ValueType)
    case optional(ValueType)
    /// A generic type with what it is bound to: `Flow<String>`.
    case generic(String, [ValueType])

    public var description: String {
        switch self {
        case .any: "Any"
        case .bool: "Bool"
        case .int: "Int"
        case .double: "Double"
        case .string: "String"
        case .record: "Record"
        case .function: "Function"
        case .named(let name): name
        case .list(let element): "[\(element)]"
        case .dictionary(let key, let value): "[\(key): \(value)]"
        case .optional(let wrapped): "\(wrapped)?"
        case .generic(let name, let arguments): "\(name)<\(arguments.map(\.description).joined(separator: ", "))>"
        }
    }
}

/// A host's function or method as a value, as `repo.log` gives it. The
/// shell calls it like any other function.
@_spi(Layer) public final class NativeFunction: Callable, @unchecked Sendable { // safe: its state is touched only holding the interpreter lock
    public let function: HostFunction

    public init(_ function: HostFunction) {
        self.function = function
    }

    public var description: String {
        "(Function)"
    }
}

/// A failure in converting between Swift and Swiit values, or one a host's function
/// throws to report a problem the way the shell's own errors read.
@_spi(Layer) public struct SwiitError: Error, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

// MARK: Converting values

/// A Swift type that can be a parameter: the shell hands it a `Value`, and
/// it says what type the shell should check for.
public protocol ValueConvertible {
    static var valueType: ValueType { get }
    /// The enums `valueType` names, for the shell to register.
    @_spi(Layer) static var swiitEnums: [EnumType] { get }
    init(_ swiitValue: Value) throws
    var value: Value { get }
}

extension ValueConvertible {
    @_spi(Layer) public static var swiitEnums: [EnumType] { [] }
}

extension Value: ValueConvertible {
    @_spi(Layer) public static var valueType: ValueType { .any }
    @_spi(Layer) public init(_ swiitValue: Value) { self = swiitValue }
    @_spi(Layer) public var value: Value { self }
}

extension Int: ValueConvertible {
    public static var valueType: ValueType { .int }
    public init(_ swiitValue: Value) throws {
        guard case .int(let value) = swiitValue else { throw SwiitError.expected("Int", swiitValue) }
        self = value
    }
    public var value: Value { .int(self) }
}

extension Double: ValueConvertible {
    public static var valueType: ValueType { .double }
    public init(_ swiitValue: Value) throws {
        switch swiitValue {
        case .double(let value): self = value
        case .int(let value): self = Double(value)
        default: throw SwiitError.expected("Double", swiitValue)
        }
    }
    public var value: Value { .double(self) }
}

extension String: ValueConvertible {
    public static var valueType: ValueType { .string }
    public init(_ swiitValue: Value) throws {
        switch swiitValue {
        case .string(let value): self = value
        default:
            // What stands for text (a command's output) is its text.
            guard let text = swiitValue.text else { throw SwiitError.expected("String", swiitValue) }
            self = text
        }
    }
    public var value: Value { .string(self) }
}

extension Bool: ValueConvertible {
    public static var valueType: ValueType { .bool }
    public init(_ swiitValue: Value) throws {
        guard case .bool(let value) = swiitValue else { throw SwiitError.expected("Bool", swiitValue) }
        self = value
    }
    public var value: Value { .bool(self) }
}

extension Date: ValueConvertible {
    public static var valueType: ValueType { .named("Date") }
    public init(_ swiitValue: Value) throws {
        guard let value = swiitValue.date else { throw SwiitError.expected("Date", swiitValue) }
        self = value
    }
    public var value: Value { .date(self) }
}

extension Array: ValueConvertible where Element: ValueConvertible {
    public static var valueType: ValueType { .list(Element.valueType) }
    @_spi(Layer) public static var swiitEnums: [EnumType] { Element.swiitEnums }
    public init(_ swiitValue: Value) throws {
        switch swiitValue {
        case .list(let items): self = try items.map(Element.init(_:))
        // A Swift sequence Swiit holds (a command's output is its lines).
        case .object(let box as SwiftValue) where box.value is any Sequence:
            self = try SwiftValue.elements(of: box.value).map { try Element(Value(reflecting: $0)) }
        default: throw SwiitError.expected("[\(Element.valueType)]", swiitValue)
        }
    }
    public var value: Value { .list(map(\.value)) }
}

extension Dictionary: ValueConvertible where Key: ValueConvertible, Value: ValueConvertible {
    public static var valueType: ValueType { .dictionary(Key.valueType, Value.valueType) }
    @_spi(Layer) public static var swiitEnums: [EnumType] { Key.swiitEnums + Value.swiitEnums }
    public init(_ swiitValue: Swiit.Value) throws {
        guard case .dictionary(let entries) = swiitValue else { throw SwiitError.expected("[\(Key.valueType): \(Value.valueType)]", swiitValue) }
        self.init(uniqueKeysWithValues: try entries.map { (try Key($0.key), try Value($0.value)) })
    }
    public var value: Swiit.Value {
        .dictionary(ValueDictionary(map { ($0.key.value, $0.value.value) }))
    }
}

extension Optional: ValueConvertible where Wrapped: ValueConvertible {
    public static var valueType: ValueType { .optional(Wrapped.valueType) }
    @_spi(Layer) public static var swiitEnums: [EnumType] { Wrapped.swiitEnums }
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
        switch self {
        case .nothing: "nil"
        case .bool: "Bool"
        case .int: "Int"
        case .double: "Double"
        case .string: "String"
        case .list: "List"
        case .record(let record): record.typeName ?? "Record"
        case .dictionary: "Dictionary"
        case .enumValue(let value): value.type.name
        case .object(let object): object.typeName
        case .function: "Function"
        }
    }

    /// A function's result, whatever Swift type it has: a convertible
    /// value, an exported object, `Encodable` data as records, or nothing.
    @_spi(Layer) public init(returning result: Any) throws {
        switch result {
        case is Void: self = .nothing
        case let value as any ValueConvertible: self = value.value
        case let object as any HostObject: self = .object(object)
        case let objects as [any HostObject]: self = .list(objects.map(Value.object))
        case let data as any Encodable: self = try ValueEncoder().encode(data)
        default: throw SwiitError("can't return a \(type(of: result)) to Swiit; make it Encodable")
        }
    }
}

/// What the shell checks a parameter's arguments against.
@_spi(Layer) public func swiitParameterType<T: ValueConvertible>(_ type: T.Type) -> ValueType { T.valueType }
/// An exported object: anything, checked when it's converted.
@_spi(Layer) public func swiitParameterType<T: HostObject>(_ type: T.Type) -> ValueType { .any }

@_spi(Layer) public func swiitParameterEnums<T: ValueConvertible>(_ type: T.Type) -> [EnumType] { T.swiitEnums }
@_spi(Layer) public func swiitParameterEnums<T: HostObject>(_ type: T.Type) -> [EnumType] { [] }

/// What a function returns, for signatures and `--help`.
@_spi(Layer) public func swiitReturnType(_ type: Any.Type) -> ValueType {
    (type as? any ValueConvertible.Type)?.valueType ?? .any
}

/// An object argument: one of the host's own classes, held as a live object.
@_spi(Layer) public func swiitArgument<T: HostObject>(
    _ arguments: [String: Value], _ name: String, of function: String, as type: T.Type = T.self
) throws -> T {
    guard case .object(let object as T) = arguments[name] ?? .nothing else {
        throw SwiitError("\(function): \(name): expected \(T.self), not \((arguments[name] ?? .nothing).bridgeTypeName)")
    }
    return object
}

/// An argument the macro-generated code converts: a clear message naming
/// the function and parameter when it doesn't fit.
@_spi(Layer) public func swiitArgument<T: ValueConvertible>(
    _ arguments: [String: Value], _ name: String, of function: String, as type: T.Type = T.self
) throws -> T {
    do {
        return try T(arguments[name] ?? .nothing)
    } catch let error as SwiitError {
        throw SwiitError("\(function): \(name): \(error)")
    }
}

/// A Swift enum Swiit can use: as a parameter (`volume .high`, or
/// `volume(.high)`), a result, and in `switch`. Conforming is all it takes,
/// for an enum without associated values:
///
///     public enum Level: String, CaseIterable, ScriptEnum { case low, high }
///
/// The shell learns it by name from the functions that take it.
public protocol ScriptEnum: ValueConvertible, CaseIterable {
    /// Its cases and raw values, as Swiit sees them; one instance per type,
    /// so values compare equal across calls.
    @_spi(Layer) static var swiitEnumType: EnumType { get }
}

extension ScriptEnum {
    @_spi(Layer) public static var swiitEnumType: EnumType {
        EnumRegistry.shared.type(for: Self.self) {
            EnumType(name: String(describing: Self.self), cases: allCases.map { value in
                let raw = (value as? any RawRepresentable)?.rawValue
                return EnumType.Case(name: String(describing: value), rawValue: raw.flatMap { raw in
                    switch raw {
                    case let int as Int: .int(int)
                    case let string as String: .string(string)
                    default: nil
                    }
                })
            })
        }
    }

    public static var valueType: ValueType { .named(swiitEnumType.name) }
    @_spi(Layer) public static var swiitEnums: [EnumType] { [swiitEnumType] }

    public init(_ swiitValue: Value) throws {
        guard case .enumValue(let value) = swiitValue, value.type === Self.swiitEnumType,
              let found = Self.allCases.first(where: { String(describing: $0) == value.name }) else {
            throw SwiitError.expected(Self.swiitEnumType.name, swiitValue)
        }
        self = found
    }

    public var value: Value {
        .enumValue(EnumValue(type: Self.swiitEnumType, name: String(describing: self)))
    }
}

/// Each `ScriptEnum`'s `EnumType`, made once.
final class EnumRegistry: @unchecked Sendable { // safe: every access holds its own lock
    static let shared = EnumRegistry()
    private let lock = NSLock()
    private var types: [ObjectIdentifier: EnumType] = [:]

    func type(for key: Any.Type, _ make: () -> EnumType) -> EnumType {
        lock.lock()
        defer { lock.unlock() }
        if let type = types[ObjectIdentifier(key)] { return type }
        let type = make()
        types[ObjectIdentifier(key)] = type
        return type
    }
}
