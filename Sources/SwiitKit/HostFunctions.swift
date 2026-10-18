import Foundation

// MARK: What a host exports

/// A Swift function as Swiit sees it: the same signature a `func` in Swiit
/// has, so it gets a command line, `--help` and completion the same way.
public struct ExportedFunction: Sendable {
    public let name: String
    public let summary: String?
    public let parameters: [ExportedParameter]
    public let returnType: SwiitType?
    /// Declared `throws`: a call to it needs `try`.
    public let isThrowing: Bool
    /// Called with every argument bound, by parameter name, except ones
    /// left to a Swift default (`defaultSource`).
    public let call: @Sendable ([String: Value]) throws -> Value

    public init(
        name: String, summary: String? = nil, parameters: [ExportedParameter], returnType: SwiitType?,
        isThrowing: Bool = false,
        call: @escaping @Sendable ([String: Value]) throws -> Value
    ) {
        self.isThrowing = isThrowing
        self.name = name
        self.summary = summary
        self.parameters = parameters
        self.returnType = returnType
        self.call = call
    }
}

public struct ExportedParameter: Sendable {
    /// nil for `_`: positional on the command line.
    public let label: String?
    public let name: String
    public let type: SwiitType
    /// The enums its type uses, which the shell learns by name.
    public let enums: [EnumType]
    public let variadic: Bool
    /// `@Input`: receives what's piped in.
    public let isInput: Bool
    /// `@Flag("n")`.
    public let shortFlag: Character?
    public let documentation: String?
    /// A literal default, which the shell fills in and `--help` shows.
    public let defaultValue: Value?
    /// A default only Swift can compute, like `Date()`: the argument is
    /// left out and the function uses its own. Its source, for `--help`.
    public let defaultSource: String?
    /// What is given is shown as interpolation shows a value (see `Parameter.showsByType`).
    public let showsByType: Bool

    public init(
        label: String?, name: String, type: SwiitType, enums: [EnumType] = [], variadic: Bool = false, isInput: Bool = false,
        shortFlag: Character? = nil, documentation: String? = nil, defaultValue: Value? = nil, defaultSource: String? = nil,
        showsByType: Bool = false
    ) {
        self.showsByType = showsByType
        self.label = label
        self.name = name
        self.type = type
        self.enums = enums
        self.variadic = variadic
        self.isInput = isInput
        self.shortFlag = shortFlag
        self.documentation = documentation
        self.defaultValue = defaultValue
        self.defaultSource = defaultSource
    }
}

/// The type of a parameter or result, as Swiit's type annotations name it.
public indirect enum SwiitType: Sendable, Hashable, CustomStringConvertible {
    case any, bool, int, double, string, record, date, output, function
    /// An enum its function uses, like `Level`.
    case named(String)
    case list(SwiitType)
    case dictionary(SwiitType, SwiitType)
    case optional(SwiitType)

    public var description: String {
        switch self {
        case .any: "Any"
        case .bool: "Bool"
        case .int: "Int"
        case .double: "Double"
        case .string: "String"
        case .record: "Record"
        case .date: "Date"
        case .output: "Output"
        case .function: "Function"
        case .named(let name): name
        case .list(let element): "[\(element)]"
        case .dictionary(let key, let value): "[\(key): \(value)]"
        case .optional(let wrapped): "\(wrapped)?"
        }
    }
}

/// A host's function or method as a value, as `repo.log` gives it. The
/// shell calls it like any other function.
public final class NativeFunction: Callable, @unchecked Sendable { // safe: its state is touched only holding the interpreter lock
    public let function: ExportedFunction

    public init(_ function: ExportedFunction) {
        self.function = function
    }

    public var description: String {
        "(Function)"
    }
}

/// A failure in converting between Swift and Swiit values, or one a host's function
/// throws to report a problem the way the shell's own errors read.
public struct SwiitError: Error, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

// MARK: Converting values

/// A Swift type that can be a parameter: the shell hands it a `Value`, and
/// it says what type the shell should check for.
public protocol SwiitConvertible {
    static var swiitType: SwiitType { get }
    /// The enums `swiitType` names, for the shell to register.
    static var swiitEnums: [EnumType] { get }
    init(swiitValue: Value) throws
    var swiitValue: Value { get }
}

extension SwiitConvertible {
    public static var swiitEnums: [EnumType] { [] }
}

extension Value: SwiitConvertible {
    public static var swiitType: SwiitType { .any }
    public init(swiitValue: Value) { self = swiitValue }
    public var swiitValue: Value { self }
}

extension Int: SwiitConvertible {
    public static var swiitType: SwiitType { .int }
    public init(swiitValue: Value) throws {
        guard case .int(let value) = swiitValue else { throw SwiitError.expected("Int", swiitValue) }
        self = value
    }
    public var swiitValue: Value { .int(self) }
}

extension Double: SwiitConvertible {
    public static var swiitType: SwiitType { .double }
    public init(swiitValue: Value) throws {
        switch swiitValue {
        case .double(let value): self = value
        case .int(let value): self = Double(value)
        default: throw SwiitError.expected("Double", swiitValue)
        }
    }
    public var swiitValue: Value { .double(self) }
}

extension String: SwiitConvertible {
    public static var swiitType: SwiitType { .string }
    public init(swiitValue: Value) throws {
        switch swiitValue {
        case .string(let value): self = value
        default:
            // What stands for text (a command's output) is its text.
            guard let text = swiitValue.text else { throw SwiitError.expected("String", swiitValue) }
            self = text
        }
    }
    public var swiitValue: Value { .string(self) }
}

extension Bool: SwiitConvertible {
    public static var swiitType: SwiitType { .bool }
    public init(swiitValue: Value) throws {
        guard case .bool(let value) = swiitValue else { throw SwiitError.expected("Bool", swiitValue) }
        self = value
    }
    public var swiitValue: Value { .bool(self) }
}

extension Date: SwiitConvertible {
    public static var swiitType: SwiitType { .date }
    public init(swiitValue: Value) throws {
        guard let value = swiitValue.date else { throw SwiitError.expected("Date", swiitValue) }
        self = value
    }
    public var swiitValue: Value { .date(self) }
}

extension Output: SwiitConvertible {
    public static var swiitType: SwiitType { .output }
    public init(swiitValue: Value) throws {
        guard let value = swiitValue.commandOutput else { throw SwiitError.expected("Output", swiitValue) }
        self = value
    }
    public var swiitValue: Value { .output(self) }
}

extension Array: SwiitConvertible where Element: SwiitConvertible {
    public static var swiitType: SwiitType { .list(Element.swiitType) }
    public static var swiitEnums: [EnumType] { Element.swiitEnums }
    public init(swiitValue: Value) throws {
        switch swiitValue {
        case .list(let items): self = try items.map(Element.init(swiitValue:))
        case _ where swiitValue.commandOutput != nil:
            self = try swiitValue.commandOutput!.lines.map { try Element(swiitValue: .string($0)) }
        default: throw SwiitError.expected("[\(Element.swiitType)]", swiitValue)
        }
    }
    public var swiitValue: Value { .list(map(\.swiitValue)) }
}

extension Dictionary: SwiitConvertible where Key: SwiitConvertible, Value: SwiitConvertible {
    public static var swiitType: SwiitType { .dictionary(Key.swiitType, Value.swiitType) }
    public static var swiitEnums: [EnumType] { Key.swiitEnums + Value.swiitEnums }
    public init(swiitValue: SwiitKit.Value) throws {
        guard case .dictionary(let entries) = swiitValue else { throw SwiitError.expected("[\(Key.swiitType): \(Value.swiitType)]", swiitValue) }
        self.init(uniqueKeysWithValues: try entries.map { (try Key(swiitValue: $0.key), try Value(swiitValue: $0.value)) })
    }
    public var swiitValue: SwiitKit.Value {
        .dictionary(ValueDictionary(map { ($0.key.swiitValue, $0.value.swiitValue) }))
    }
}

extension Optional: SwiitConvertible where Wrapped: SwiitConvertible {
    public static var swiitType: SwiitType { .optional(Wrapped.swiitType) }
    public static var swiitEnums: [EnumType] { Wrapped.swiitEnums }
    public init(swiitValue: Value) throws {
        self = swiitValue == .nothing ? nil : try Wrapped(swiitValue: swiitValue)
    }
    public var swiitValue: Value { map(\.swiitValue) ?? .nothing }
}

extension SwiitError {
    static func expected(_ type: String, _ value: Value) -> SwiitError {
        SwiitError("expected \(type), not \(value.typeName)")
    }
}

extension Value {
    /// The type name error messages use.
    var typeName: String {
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
    public init(returning result: Any) throws {
        switch result {
        case is Void: self = .nothing
        case let value as any SwiitConvertible: self = value.swiitValue
        case let object as any SwiitObject: self = .object(object)
        case let objects as [any SwiitObject]: self = .list(objects.map(Value.object))
        case let data as any Encodable: self = try ValueEncoder().encode(data)
        default: throw SwiitError("can't return a \(type(of: result)) to Swiit; make it Encodable")
        }
    }
}

/// What the shell checks a parameter's arguments against.
public func swiitParameterType<T: SwiitConvertible>(_ type: T.Type) -> SwiitType { T.swiitType }
/// An exported object: anything, checked when it's converted.
public func swiitParameterType<T: SwiitObject>(_ type: T.Type) -> SwiitType { .any }

public func swiitParameterEnums<T: SwiitConvertible>(_ type: T.Type) -> [EnumType] { T.swiitEnums }
public func swiitParameterEnums<T: SwiitObject>(_ type: T.Type) -> [EnumType] { [] }

/// What a function returns, for signatures and `--help`.
public func swiitReturnType(_ type: Any.Type) -> SwiitType {
    (type as? any SwiitConvertible.Type)?.swiitType ?? .any
}

/// An object argument: one of the host's own classes, held as a live object.
public func swiitArgument<T: SwiitObject>(
    _ arguments: [String: Value], _ name: String, of function: String, as type: T.Type = T.self
) throws -> T {
    guard case .object(let object as T) = arguments[name] ?? .nothing else {
        throw SwiitError("\(function): \(name): expected \(T.self), not \((arguments[name] ?? .nothing).typeName)")
    }
    return object
}

/// An argument the macro-generated code converts: a clear message naming
/// the function and parameter when it doesn't fit.
public func swiitArgument<T: SwiitConvertible>(
    _ arguments: [String: Value], _ name: String, of function: String, as type: T.Type = T.self
) throws -> T {
    do {
        return try T(swiitValue: arguments[name] ?? .nothing)
    } catch let error as SwiitError {
        throw SwiitError("\(function): \(name): \(error)")
    }
}

/// A Swift enum Swiit can use: as a parameter (`volume .high`, or
/// `volume(.high)`), a result, and in `switch`. Conforming is all it takes,
/// for an enum without associated values:
///
///     public enum Level: String, CaseIterable, SwiitEnum { case low, high }
///
/// The shell learns it by name from the functions that take it.
public protocol SwiitEnum: SwiitConvertible, CaseIterable {
    /// Its cases and raw values, as Swiit sees them; one instance per type,
    /// so values compare equal across calls.
    static var swiitEnumType: EnumType { get }
}

extension SwiitEnum {
    public static var swiitEnumType: EnumType {
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

    public static var swiitType: SwiitType { .named(swiitEnumType.name) }
    public static var swiitEnums: [EnumType] { [swiitEnumType] }

    public init(swiitValue: Value) throws {
        guard case .enumValue(let value) = swiitValue, value.type === Self.swiitEnumType,
              let found = Self.allCases.first(where: { String(describing: $0) == value.name }) else {
            throw SwiitError.expected(Self.swiitEnumType.name, swiitValue)
        }
        self = found
    }

    public var swiitValue: Value {
        .enumValue(EnumValue(type: Self.swiitEnumType, name: String(describing: self)))
    }
}

/// Each `SwiitEnum`'s `EnumType`, made once.
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

// MARK: Markers

/// `@Flag("n") times: Int = 1`: a short flag on the command line. It only
/// marks the parameter for the bridge generator; the value passes through.
/// `@Flag all: Bool = false` alone makes the parameter's first letter the
/// flag (`-a`), which is the form a symbol graph can read: it keeps the
/// attribute's name but not its arguments.
@propertyWrapper
public struct Flag<T> {
    public var wrappedValue: T
    public init(wrappedValue: T, _ short: Character) { self.wrappedValue = wrappedValue }
    public init(wrappedValue: T) { self.wrappedValue = wrappedValue }
}

/// `@Rest _ paths: [FilePath] = []`: takes any number of arguments, as
/// `FilePath...` does in Swift, which can't pass the array on to another
/// variadic: so it's declared as the array, and marked.
@propertyWrapper
public struct Rest<T> {
    public var wrappedValue: T
    public init(wrappedValue: T) { self.wrappedValue = wrappedValue }
}

/// `@Input _ lines: [String]`: receives what's piped in, per item, or the
/// whole stream for a list. Only a marker for the bridge generator.
@propertyWrapper
public struct Input<T> {
    public var wrappedValue: T
    public init(wrappedValue: T) { self.wrappedValue = wrappedValue }
}

