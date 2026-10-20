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

        /// A parameter of a Swift type: `Parameter(name: "count", type: Int.self)`.
        public init<T: ValueConvertible>(label: String? = nil, name: String, type: T.Type, defaultValue: Value? = nil, isVariadic: Bool = false) {
            self.init(label: label, name: name, type: ValueType(type), defaultValue: defaultValue, isVariadic: isVariadic)
            self.enums = T.swiitEnums
        }

        /// The enums its type uses, which the host learns by name.
        var enums: [EnumType]
        var documentation: String?
        /// A default only Swift can compute, like `Date()`: the argument is left out and the function uses its own.
        /// Its source, for `--help`.
        var defaultSource: String?
        /// What is given is shown as interpolation shows a value.
        var showsByType = false

        init(
            label: String?, name: String, type: ValueType, enums: [EnumType] = [], variadic: Bool = false,
            documentation: String? = nil, defaultValue: Value? = nil, defaultSource: String? = nil,
            showsByType: Bool = false
        ) {
            self.showsByType = showsByType
            self.label = label
            self.name = name
            self.type = type
            self.enums = enums
            self.isVariadic = variadic
            self.documentation = documentation
            self.defaultValue = defaultValue
            self.defaultSource = defaultSource
        }

        var variadic: Bool { isVariadic }
    }

    public let name: String
    /// The line `help` shows.
    public let summary: String?
    public let parameters: [Parameter]
    public let returns: ValueType?
    /// Declared `throws`: a call to it needs `try`.
    public let isThrowing: Bool
    /// Called with every argument bound, by parameter name, except ones left to a Swift default.
    let call: @Sendable ([String: Value]) throws -> Value

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

    /// A function whose result is a Swift type: `HostFunction(name: "size", returns: Int.self) { _ in 3 }`.
    public init<T: ValueConvertible>(
        name: String, summary: String? = nil, parameters: [Parameter] = [], returns: T.Type, isThrowing: Bool = false,
        body: @escaping @Sendable ([Value]) throws -> Value
    ) {
        self.init(name: name, summary: summary, parameters: parameters, returns: ValueType(returns), isThrowing: isThrowing, body: body)
    }

    /// As the host's commands are described: a body taking the arguments by name.
    init(
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

    var returnType: ValueType? { returns }
}

/// How a host names a type: a parameter or result of a function it offers, and what `symbols`, `resolveOverload` and
/// `valueType(of:)` speak. Swift's type grammar is small and closed, and so is this: a name with the types it is generic over
/// (`Int`, `Array<Int>`, `Optional<String>`, `Flow<String>`), a function type, a tuple type. Whether a named type is a struct,
/// an enum or a class is a fact about its declaration: `symbols(named:)` says.
public indirect enum ValueType: Sendable, Hashable, CustomStringConvertible {
    case named(String, [ValueType] = [])
    case function(parameters: [ValueType], returns: ValueType)
    case tuple([Element])

    /// An element of a tuple type, labeled or not.
    public struct Element: Sendable, Hashable {
        public var label: String?
        public var type: ValueType
        public init(label: String? = nil, type: ValueType) {
            self.label = label
            self.type = type
        }

        /// An element of a Swift type: `Element(label: "by", type: String.self)`.
        public init<T: ValueConvertible>(label: String? = nil, type: T.Type) {
            self.init(label: label, type: ValueType(type))
        }
    }

    /// The type of a Swift type a script can use: `ValueType(Int.self)`, `ValueType([String].self)`; any `ValueConvertible`.
    public init<T: ValueConvertible>(_ type: T.Type) {
        self = T.valueType
    }

    public static let any = ValueType.named("Any")
    public static let bool = ValueType.named("Bool")
    public static let int = ValueType.named("Int")
    public static let double = ValueType.named("Double")
    public static let string = ValueType.named("String")
    /// A function whose signature is not said.
    public static let callable = ValueType.named("Function")

    /// `[Element]`, which is `Array<Element>`.
    public static func list(_ element: ValueType) -> ValueType { .named("Array", [element]) }
    /// `[Key: Value]`, which is `Dictionary<Key, Value>`.
    public static func dictionary(_ key: ValueType, _ value: ValueType) -> ValueType { .named("Dictionary", [key, value]) }
    /// `Wrapped?`, which is `Optional<Wrapped>`.
    public static func optional(_ wrapped: ValueType) -> ValueType { .named("Optional", [wrapped]) }

    public var description: String {
        switch self {
        case .named("Array", let arguments) where arguments.count == 1: "[\(arguments[0])]"
        case .named("Dictionary", let arguments) where arguments.count == 2: "[\(arguments[0]): \(arguments[1])]"
        case .named("Optional", let arguments) where arguments.count == 1: "\(arguments[0])?"
        case .named(let name, let arguments): arguments.isEmpty ? name : "\(name)<\(arguments.map(\.description).joined(separator: ", "))>"
        case .function(let parameters, let returns): "(\(parameters.map(\.description).joined(separator: ", "))) -> \(returns)"
        case .tuple(let elements): "(" + elements.map { ($0.label.map { "\($0): " } ?? "") + $0.type.description }.joined(separator: ", ") + ")"
        }
    }
}

/// A host's function or method as a value, as `repo.log` gives it. The
/// host calls it like any other function.
final class NativeFunction: Callable, @unchecked Sendable { // safe: its state is touched only holding the interpreter lock
    public let function: HostFunction

    public init(_ function: HostFunction) {
        self.function = function
    }

    public var description: String {
        "(Function)"
    }
}

/// A failure in converting between Swift and Swiit values, or one a host's function
/// throws to report a problem the way the host's own errors read.
struct SwiitError: Error, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

// MARK: Converting values

/// A Swift type that can be a parameter: the host hands it a `Value`, and
/// it says what type the host should check for.
public protocol ValueConvertible {
    static var valueType: ValueType { get }
    init(_ swiitValue: Value) throws
    var value: Value { get }
}

/// A type that names enums in its `valueType`, which scripts learn by name: containers hold their elements'. An SPI refinement,
/// because a requirement only the module can see cannot be satisfied by a conformance outside it.
protocol ValueEnums { static var enumTypes: [EnumType] { get } }

extension ValueConvertible {
    /// The enums `valueType` names.
    static var swiitEnums: [EnumType] {
        if let carrier = self as? any ValueEnums.Type { return carrier.enumTypes }
        if let script = self as? any ScriptEnum.Type { return [script.swiitEnumType] }
        return []
    }
}

extension Value: ValueConvertible {
    public static var valueType: ValueType { .any }
    public init(_ swiitValue: Value) { self = swiitValue }
    public var value: Value { self }
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

extension Array: ValueEnums where Element: ValueConvertible {}
extension Dictionary: ValueEnums where Key: ValueConvertible, Value: ValueConvertible {}
extension Optional: ValueEnums where Wrapped: ValueConvertible {}

extension Array: ValueConvertible where Element: ValueConvertible {
    public static var valueType: ValueType { .list(Element.valueType) }
    static var enumTypes: [EnumType] { Element.swiitEnums }
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
    static var enumTypes: [EnumType] { Key.swiitEnums + Value.swiitEnums }
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
    static var enumTypes: [EnumType] { Wrapped.swiitEnums }
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
    init(returning result: Any) throws {
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

/// What the host checks a parameter's arguments against.
func swiitParameterType<T: ValueConvertible>(_ type: T.Type) -> ValueType { T.valueType }
/// An exported object: anything, checked when it's converted.
func swiitParameterType<T: HostObject>(_ type: T.Type) -> ValueType { .any }

func swiitParameterEnums<T: ValueConvertible>(_ type: T.Type) -> [EnumType] { T.swiitEnums }
func swiitParameterEnums<T: HostObject>(_ type: T.Type) -> [EnumType] { [] }

/// What a function returns, for signatures and `--help`.
func swiitReturnType(_ type: Any.Type) -> ValueType {
    (type as? any ValueConvertible.Type)?.valueType ?? .any
}

/// An object argument: one of the host's own classes, held as a live object.
func swiitArgument<T: HostObject>(
    _ arguments: [String: Value], _ name: String, of function: String, as type: T.Type = T.self
) throws -> T {
    guard case .object(let object as T) = arguments[name] ?? .nothing else {
        throw SwiitError("\(function): \(name): expected \(T.self), not \((arguments[name] ?? .nothing).bridgeTypeName)")
    }
    return object
}

/// An argument the macro-generated code converts: a clear message naming
/// the function and parameter when it doesn't fit.
func swiitArgument<T: ValueConvertible>(
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
/// The host learns it by name from the functions that take it.
public protocol ScriptEnum: ValueConvertible, CaseIterable {
    /// Its cases and raw values, as Swiit sees them; one instance per type,
    /// so values compare equal across calls.
    static var swiitEnumType: EnumType { get }
}

extension ScriptEnum {
    static var swiitEnumType: EnumType {
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
