import Foundation

/// A value flowing through Swiit.
///
/// This is the currency shared by the interpreter and its hosts,
/// which is why it lives in its own dynamic library.
public struct Value: Sendable {
    // The representation is the interpreter's: a host builds a value with its initializers,
    // literals and static members, and reads one with `casting(to:)`, `typeID`, `isInstance(of:)`,
    // `entries` and the views (`tuple`, `structure`, `enumCase`), so a new representation never
    // breaks it.
    var storage: Storage

    init(_ storage: Storage) { self.storage = storage }

    /// What a value is made of: the interpreter's fast representation.
    enum Storage: Sendable {
        case nothing
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case list([Value])
        /// A tuple: elements in order, each labeled or not: `(name: "x", 2)`.
        case tuple(Value.Tuple)
        /// A struct's value: its type's name, and its fields in the order the type declares them.
        case structure(Value.Structure)
        /// `["a": 1]`: keys to values, as Swift's Dictionary, unordered.
        case dictionary([Value: Value])
        /// A case of an enum: `.directory`, or `.failed(code: 2)`.
        case enumValue(Value.EnumCase)
        /// A live value with members of its own: a background job, an enum type,
        /// and later bridged Swift objects.
        case object(any LanguageObject)
        case function(any Callable)
    }

    /// `nil`, which a script writes `nil`. The language's own `nil` is a value, as a list's element or
    /// a field or an argument is, which a Swift `Optional<Value>` cannot say: that one is absent. The
    /// other kinds are made with `Value(3)`, `Value("x")` and the rest of the initializers; the
    /// static functions of the same names are the interpreter's own shorthand.
    public static let nothing = Value(Storage.nothing)
    static func bool(_ value: Bool) -> Value { Value(Storage.bool(value)) }
    static func int(_ value: Int) -> Value { Value(Storage.int(value)) }
    static func double(_ value: Double) -> Value { Value(Storage.double(value)) }
    static func string(_ value: String) -> Value { Value(Storage.string(value)) }
    static func list(_ values: [Value]) -> Value { Value(Storage.list(values)) }
    var isFunction: Bool { if case .function = storage { true } else { false } }
    var isString: Bool { if case .string = storage { true } else { false } }
    var isBool: Bool { if case .bool = storage { true } else { false } }
    var isInt: Bool { if case .int = storage { true } else { false } }
    static func tuple(_ value: Value.Tuple) -> Value { Value(Storage.tuple(value)) }
    static func structure(_ value: Value.Structure) -> Value { Value(Storage.structure(value)) }
    static func dictionary(_ value: [Value: Value]) -> Value { Value(Storage.dictionary(value)) }
    static func enumValue(_ value: Value.EnumCase) -> Value { Value(Storage.enumValue(value)) }
    static func object(_ value: any LanguageObject) -> Value { Value(Storage.object(value)) }
    static func function(_ value: any Callable) -> Value { Value(Storage.function(value)) }
}

extension Value {
    /// A list of values, as they are: what `Value(items)` would make by converting each one, which
    /// takes time in step with the list.
    public init(list values: [Value]) { self = .list(values) }
}

extension Value: ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral,
    ExpressibleByStringLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: Value...) { self = .list(elements) }
    public init(dictionaryLiteral elements: (Value, Value)...) {
        self = .dictionary(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
}
