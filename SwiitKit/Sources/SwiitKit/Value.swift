import Foundation

/// A value flowing through Swish.
///
/// This is the currency shared by the interpreter and every compiled plugin,
/// which is why it lives in its own dynamic library.
public enum Value: Sendable {
    case nothing
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case list([Value])
    /// Named fields in order, like a row of a table: a struct's value (with
    /// its type's name), or a tuple (without).
    case record(Record)
    /// `["a": 1]`: keys to values, as Swift's Dictionary, unordered.
    case dictionary(ValueDictionary)
    /// A case of an enum: `.directory`, or `.failed(code: 2)`.
    case enumValue(EnumValue)
    /// A live value with members of its own: a background job, an enum type,
    /// and later bridged Swift objects.
    case object(any SwiitObject)
    case function(any Callable)
}

/// A live value that answers for its own members, properties and methods
/// alike (a method is a function value). Objects compare by identity.
public protocol SwiitObject: AnyObject, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// The name `members` and error messages use, like `Job`.
    var typeName: String { get }
    /// Names of its members, for `members` and completion.
    var memberNames: [String] { get }
    /// The member called `name`, or nil if it has none.
    func member(_ name: String) -> Value?
    /// Its data as a record, which tables, `select` and `to json` use; nil
    /// for an object that isn't data, like an enum type.
    var fields: Record? { get }
    /// How it prints in the debug form, in pieces to color, if it has a form
    /// of its own (a job reads `[1] running  make`); nil to print as its fields.
    var displaySegments: [DisplaySegment]? { get }
    /// What equality and hashing go by: the object itself, by default; a
    /// boxed Swift value's own value, when it's Hashable.
    var identity: AnyHashable { get }
}

/// A piece of text and the style it's shown in.
public typealias DisplaySegment = (text: String, style: DisplayStyle?)

extension SwiitObject {
    public var identity: AnyHashable { AnyHashable(ObjectIdentifier(self)) }

    public var displaySegments: [DisplaySegment]? { nil }

    /// Every member that isn't a method, in `memberNames` order.
    public var fields: Record? {
        var record = Record(typeName: typeName)
        for name in memberNames {
            guard let value = member(name) else { continue }
            if case .function = value { continue }
            record[name] = value
        }
        return record
    }

    /// Its fields, as a Swift struct prints them: `Job(id: 1, …)`; or its
    /// description, for an object that isn't data.
    public var debugDescription: String {
        fields?.debugDescription ?? description
    }
}

/// A Swish value as a Swift function takes or gives one whole, whatever it
/// is. The name tells a bridged function's parameter from a generic parameter
/// called `Value`.
public typealias SwiitValue = Value

extension Value {
    /// A record, or an object's fields: what a table row is made from.
    public var asRecord: Record? {
        switch self {
        case .record(let record): record
        case .object(let object): object.fields
        default: nil
        }
    }
}

/// A type that holds a Swish value as it is, whose type says how it's read:
/// `JSON`, which is whatever it parsed as. A function that gives one gives
/// the value it holds.
public protocol WrapsValue {
    var value: Value { get }
    init(_ value: Value)
}

/// A function value. The interpreter implements this for Swish functions and
/// closures; plugins will implement it for bridged Swift functions.
public protocol Callable: AnyObject, Sendable, CustomStringConvertible {}

/// Fields in insertion order. Two records are equal when they have the same
/// fields, whatever their order or type name.
public struct Record: Sendable, Hashable, Sequence {
    public private(set) var keys: [String] = []
    private var storage: [String: Value] = [:]
    /// The Swift type this record came from, like `FileEntry`, which picks
    /// how it's displayed.
    public var typeName: String?

    public init(typeName: String? = nil) {
        self.typeName = typeName
    }

    public init(_ fields: KeyValuePairs<String, Value>, typeName: String? = nil) {
        self.typeName = typeName
        for (key, value) in fields { self[key] = value }
    }

    public subscript(key: String) -> Value? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public var count: Int { keys.count }

    public func makeIterator() -> some IteratorProtocol<(key: String, value: Value)> {
        keys.lazy.map { (key: $0, value: storage[$0]!) }.makeIterator()
    }

    public static func == (lhs: Record, rhs: Record) -> Bool {
        lhs.storage == rhs.storage
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(storage)
    }
}

extension Record: CustomStringConvertible, CustomDebugStringConvertible {
    /// As its type would print, `Status(code: 0, …)`, or as a tuple,
    /// `(name: "x", 2)`, for a record without one; a tuple's unlabeled
    /// elements are keyed by position.
    public var debugDescription: String {
        (typeName ?? "") + "(" + map { field in
            (Record.isPosition(field.key) ? "" : "\(field.key): ") + field.value.debugDescription
        }.joined(separator: ", ") + ")"
    }

    /// What interpolation shows: like `debugDescription`, with text unquoted.
    public var description: String {
        (typeName ?? "") + "(" + map { field in
            (Record.isPosition(field.key) ? "" : "\(field.key): ") + field.value.description
        }.joined(separator: ", ") + ")"
    }

    /// `0`, `1`, …: the key of a tuple element without a label.
    public static func isPosition(_ key: String) -> Bool {
        !key.isEmpty && key.allSatisfy(\.isNumber)
    }
}

/// Swift's `[Value: Value]`: iterating it goes in Swift's order, which is
/// no particular one and changes from run to run. Shown, it's sorted by key
/// (`sortedForDisplay`), so what's printed is the same every time.
public struct ValueDictionary: Sendable, Hashable, Sequence, CustomStringConvertible, CustomDebugStringConvertible {
    public var dictionary: [Value: Value]

    public init() { dictionary = [:] }

    public init(_ dictionary: [Value: Value]) { self.dictionary = dictionary }

    /// Later entries replace earlier ones with the same key.
    public init(_ entries: [(Value, Value)]) {
        dictionary = Dictionary(entries, uniquingKeysWith: { $1 })
    }

    public subscript(key: Value) -> Value? {
        get { dictionary[key] }
        set { dictionary[key] = newValue }
    }

    public var count: Int { dictionary.count }
    public var keys: [Value] { Array(dictionary.keys) }
    public var values: [Value] { Array(dictionary.values) }

    public func makeIterator() -> some IteratorProtocol<(key: Value, value: Value)> {
        dictionary.makeIterator()
    }

    /// The entries sorted by key: numbers by value, strings as Swift sorts
    /// them, an enum's cases in declared order, and anything else by how
    /// it's written.
    public var sortedForDisplay: [(key: Value, value: Value)] {
        dictionary.sorted { Value.displaysBefore($0.key, $1.key) }
    }

    public var debugDescription: String {
        guard count > 0 else { return "[:]" }
        return "[" + sortedForDisplay.map { "\($0.key.debugDescription): \($0.value.debugDescription)" }.joined(separator: ", ") + "]"
    }

    public var description: String { debugDescription }
}

extension Value {
    /// A file size, held as the Swift value it is.
    public static func fileSize(_ size: FileSize) -> Value {
        SwiftValue.make(size, as: "FileSize")
    }

    /// The file size it holds, if it's one.
    public var fileSize: FileSize? {
        if case .object(let box as SwiftValue) = self { box.value as? FileSize } else { nil }
    }

    /// The order a dictionary's keys are shown in: only for showing, so it
    /// needn't mean anything beyond being the same every time.
    static func displaysBefore(_ a: Value, _ b: Value) -> Bool {
        switch (a, b) {
        case (.int(let x), .int(let y)): return x < y
        case (.int, .double), (.double, .int), (.double, .double):
            return a.displayNumber! < b.displayNumber!
        case (.string(let x), .string(let y)): return x < y
        case (.bool(let x), .bool(let y)): return !x && y
        case (.enumValue(let x), .enumValue(let y)) where x.type === y.type && x.index != y.index: return x.index < y.index
        default:
            return a.debugDescription < b.debugDescription
        }
    }

    private var displayNumber: Double? {
        switch self {
        case .int(let n): Double(n)
        case .double(let d): d
        default: nil
        }
    }
}

extension Value: Hashable {
    /// Functions compare by identity.
    public static func == (lhs: Value, rhs: Value) -> Bool {
        switch (lhs, rhs) {
        case (.nothing, .nothing): true
        case (.bool(let a), .bool(let b)): a == b
        case (.int(let a), .int(let b)): a == b
        case (.double(let a), .double(let b)): a == b
        case (.string(let a), .string(let b)): a == b
        case (.list(let a), .list(let b)): a == b
        case (.record(let a), .record(let b)): a == b
        case (.dictionary(let a), .dictionary(let b)): a == b
        case (.enumValue(let a), .enumValue(let b)): a == b
        case (.object(let a), .object(let b)): a === b || a.identity == b.identity
        case (.function(let a), .function(let b)): a === b
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .nothing: hasher.combine(0)
        case .bool(let value): hasher.combine(value)
        case .int(let value): hasher.combine(value)
        case .double(let value): hasher.combine(value)
        case .string(let value): hasher.combine(value)
        case .list(let values): hasher.combine(values)
        case .record(let record): hasher.combine(record)
        case .dictionary(let dictionary): hasher.combine(dictionary)
        case .enumValue(let value): hasher.combine(value)
        case .object(let object): hasher.combine(object.identity)
        case .function(let function): hasher.combine(ObjectIdentifier(function))
        }
    }
}

extension Value: CustomStringConvertible {
    public var description: String {
        switch self {
        case .nothing: ""
        case .bool(let value): String(value)
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .string(let value): value
        case .list(let values): "[" + values.map(\.description).joined(separator: ", ") + "]"
        case .record(let record): record.description
        case .dictionary(let dictionary): dictionary.description
        case .enumValue(let value): value.description
        case .object(let object): object.description
        case .function(let function): function.description
        }
    }

}

extension Value {
    /// A string as a literal: quotes, backslashes and control characters
    /// escaped. Like Swift's `debugDescription`, but a `'` stays as it is.
    public static func quoted(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                result += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}

extension Value: CustomDebugStringConvertible {
    /// As Swift's `debugPrint` shows it, and as the prompt shows a bare
    /// value: strings quoted, cases with their type, outputs and records
    /// with their fields.
    public var debugDescription: String {
        switch self {
        case .nothing: "nil"
        case .string(let value): Value.quoted(value)
        case .list(let values): "[" + values.map(\.debugDescription).joined(separator: ", ") + "]"
        case .record(let record): record.debugDescription
        case .dictionary(let dictionary): dictionary.debugDescription
        case .enumValue(let value): value.debugDescription
        case .object(let object): object.debugDescription
        default: description
        }
    }
}

extension Value {
    /// A date, held as the Swift value it is.
    public static func date(_ date: Date) -> Value {
        SwiftValue.make(date, as: "Date")
    }

    /// The date it holds, if it's one.
    public var date: Date? {
        if case .object(let box as SwiftValue) = self { box.value as? Date } else { nil }
    }
}
