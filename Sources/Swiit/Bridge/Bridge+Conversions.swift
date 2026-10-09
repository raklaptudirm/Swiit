import Foundation
import SwishKit
import SwishStandardLibrary
import SystemPackage

/// A Swish key path (`\.status.code`, or `--by size`) as a Swift one over
/// values: each name a subscript that reads the field, one after another.
@_spi(Shell) public func bridgeKeyPath(_ value: Value) throws -> KeyPath<Value, Value> {
    guard case .function(let keyPath as KeyPathValue) = value else {
        throw SwishError("expected a key path, not \(value.typeName)")
    }
    return keyPath.path.reduce(\Value.self) { path, name in path.appending(path: \Value.[field: name]) }
}

/// Runs `body`, which reads fields through key paths, with fields read as the
/// shell reads them; the first failure (a field that isn't there) is thrown
/// after it, since a key path can't throw.
@_spi(Shell) public func withFieldReader<T>(_ shell: Interpreter, _ body: () throws -> T) throws -> T {
    var failure: Error?
    let saved = FieldAccess.reader
    FieldAccess.reader = { value, name in
        do { return try shell.member(name, of: value) } catch {
            failure = failure ?? error
            return .nothing
        }
    }
    defer { FieldAccess.reader = saved }
    let result = try body()
    if let failure { throw failure }
    return result
}

/// A case of a Swift enum from a Swish value: the case of that name, among
/// all the enum's.
@_spi(Shell) public func bridgeCase<T: CaseIterable>(_ type: T.Type, _ value: Value) throws -> T {
    guard case .enumValue(let found) = value, let match = T.allCases.first(where: { "\($0)" == found.name }) else {
        throw SwishError("expected a \(T.self), not \(value.typeName)")
    }
    return match
}

/// A path as Swish holds it: a FilePath.
@_spi(Shell) public func pathValue(_ path: String) -> Value {
    SwiftValue.make(FilePath(path), as: "FilePath")
}

/// What a record's field is that encoding loses: an enum is encoded as its
/// raw text and a path as an object, and Swish holds them as what they are.
@_spi(Shell) public enum FieldKind {
    case enumeration(String)
    /// A Swift type held as it is, of this name: a `FilePath`, a `FileSize`.
    case boxed(String)
}

/// A Swift struct as a record, its fields by name, in the order it declares
/// them and all there: the encoder leaves out a nil, and the declaration says
/// it's a field. A field of `patches` is read from the Swift value itself and
/// made what it is declared as.
@_spi(Shell) public func bridgeRecord<T: Encodable>(_ shell: Interpreter, _ value: T, patches: [String: FieldKind] = [:]) -> Value {
    guard case .record(let encoded)? = try? ValueEncoder().encode(value) else { return .nothing }
    var record = Record(typeName: encoded.typeName)
    for child in Mirror(reflecting: value).children {
        guard let field = child.label else { continue }
        var held: Any? = child.value
        // An optional holds its value, or nothing.
        if let optional = held.map(Mirror.init(reflecting:)), optional.displayStyle == .optional {
            held = optional.children.first?.value
        }
        record[field] = switch (patches[field], held) {
        case (.enumeration(let type)?, let held?): shell.declaredCase(type, "\(held)")
        case (.boxed(let type)?, let held?): SwiftValue.make(held, as: type)
        case (_, .some): encoded[field] ?? .nothing
        default: .nothing
        }
    }
    return .record(record)
}

extension Interpreter {
    /// What a standard library function that asks for it is lent.
    @_spi(Shell) public var context: ShellContext {
        ShellContext(history: historyEntries, colorOutput: host.output.traits().styled, display: displayRegistryProvider())
    }
}

/// A list's items, or an Output's lines.
@_spi(Shell) public func bridgeList(_ value: Value) throws -> [Value] {
    switch value {
    case .list(let items): return items
    default:
        guard let output = value.commandOutput else { throw SwishError("expected a list, not \(value.typeName)") }
        return output.lines.map(Value.string)
    }
}

/// A dictionary as Swift's, which is what it holds.
@_spi(Shell) public func bridgeDictionary(_ value: Value) throws -> [Value: Value] {
    guard case .dictionary(let dictionary) = value else { throw SwishError("expected a dictionary, not \(value.typeName)") }
    return dictionary.dictionary
}

/// Swift's dictionary as Swish's.
@_spi(Shell) public func bridgeDictionary(_ dictionary: [Value: Value]) -> Value {
    .dictionary(ValueDictionary(dictionary))
}

/// A tuple's elements, by label or position, made into a Swift tuple.
@_spi(Shell) public func bridgeTuple<T>(_ value: Value, _ labels: [String?], _ make: ([Value]) throws -> T) throws -> T {
    guard case .record(let record) = value, record.typeName == nil, record.count == labels.count else {
        throw SwishError("expected a tuple of \(labels.count), not \(value.typeName)")
    }
    return try make(labels.enumerated().map { index, label in
        label.flatMap { record[$0] } ?? record[record.keys[index]]!
    })
}

/// A Swift tuple as Swish's, from its elements' labels and values.
@_spi(Shell) public func bridgeTuple<T>(_ tuple: T, _ elements: (T) -> [(String?, Value)]) -> Value {
    var record = Record()
    for (index, (label, value)) in elements(tuple).enumerated() { record[label ?? String(index)] = value }
    return .record(record)
}

/// The items of any sequence, for a Swift parameter that takes one: a
/// String's Characters, a dictionary's (key, value) pairs, or what
/// `Shell.items(of:)` gives.
@_spi(Shell) public func bridgeSequence(_ value: Value) throws -> [Value] {
    switch value {
    case .string(let text):
        return Array(Interpreter.iterator(text))
    case .dictionary(let dictionary):
        return dictionary.map { bridgeTuple(($0.key, $0.value)) { [("key", $0.0), ("value", $0.1)] } }
    default:
        guard let items = Interpreter.items(of: value) else { throw SwishError("expected a sequence, not \(value.typeName)") }
        return Array(items)
    }
}

/// A range with bounds of a Swift type, from Swish's range of values.
@_spi(Shell) public func bridgeRange<Bound: Comparable>(_ value: Value, _ bound: (Value) throws -> Bound) throws -> Range<Bound> {
    let range = try SwiftValue.unbox(Range<Value>.self, value)
    return Range(uncheckedBounds: (lower: try bound(range.lowerBound), upper: try bound(range.upperBound)))
}

@_spi(Shell) public func bridgeClosedRange<Bound: Comparable>(_ value: Value, _ bound: (Value) throws -> Bound) throws -> ClosedRange<Bound> {
    let range = try SwiftValue.unbox(ClosedRange<Value>.self, value)
    return ClosedRange(uncheckedBounds: (lower: try bound(range.lowerBound), upper: try bound(range.upperBound)))
}

/// A Swift value boxed as Swish holds it, converted first (a `Set<Int>` to
/// a `Set<Value>`).
@_spi(Shell) public func bridgeBox<T, Boxed>(_ value: T, as typeName: String, _ convert: (T) -> Boxed) -> Value {
    SwiftValue.make(convert(value), as: typeName)
}

@_spi(Shell) public func bridgeBox<T, Boxed: Hashable>(_ value: T, as typeName: String, _ convert: (T) -> Boxed) -> Value {
    SwiftValue.make(convert(value), as: typeName)
}

/// `lower...upper` or `lower..<upper`, of any values that compare.
@_spi(Shell) public func makeRange(_ op: BinaryOperator, _ lower: Value, _ upper: Value) throws -> Value {
    guard lower <= upper else { throw RuntimeError("range \(lower)\(op.rawValue)\(upper) has its bounds reversed") }
    if op == .closedRange { return SwiftValue.make(ClosedRange(uncheckedBounds: (lower: lower, upper: upper)), as: "ClosedRange") }
    return SwiftValue.make(Range(uncheckedBounds: (lower: lower, upper: upper)), as: "Range")
}

extension Interpreter {
    /// The items a value gives as they come, which can throw: a `Flow`'s,
    /// one at a time; nil for anything else.
    @_spi(Shell) public static func flow(of value: Value) -> Flow<Value>? {
        if case .object(let box as SwiftValue) = value { box.value as? Flow<Value> } else { nil }
    }

    /// The items of a list, an Output's lines, or a Swift sequence Swish
    /// holds (a Set, a range of Ints, a dictionary's keys), one at a time,
    /// so a range of a billion never becomes a list; nil for anything else.
    @_spi(Shell) public static func items(of value: Value) -> AnyIterator<Value>? {
        switch value {
        case .list(let items):
            return AnyIterator(items.makeIterator())
        case .object(let box as SwiftValue):
            if let output = box.value as? Output {
                return AnyIterator(output.lines.lazy.map(Value.string).makeIterator())
            }
            if let range = box.value as? ClosedRange<Value> {
                guard case .int(let lower) = range.lowerBound, case .int(let upper) = range.upperBound else { return nil }
                return AnyIterator((lower...upper).lazy.map(Value.int).makeIterator())
            }
            if let range = box.value as? Range<Value> {
                guard case .int(let lower) = range.lowerBound, case .int(let upper) = range.upperBound else { return nil }
                return AnyIterator((lower..<upper).lazy.map(Value.int).makeIterator())
            }
            guard let sequence = box.value as? any Sequence else { return nil }
            return iterator(sequence)
        default:
            return nil
        }
    }

    /// A Swift sequence's elements as Swish values, boxed by their type's name.
    @_spi(Shell) public static func iterator<S: Sequence>(_ sequence: S) -> AnyIterator<Value> {
        var iterator = sequence.makeIterator()
        return AnyIterator {
            guard let next = iterator.next() else { return nil }
            if let value = next as? Value { return value }
            // By the name Swish writes it with, without its module:
            // FilePath.Component, not SystemPackage.FilePath.Component.
            let name = String(reflecting: type(of: next))
            let unqualified = String(name.drop { $0 != "." }.dropFirst())
            return SwiftValue.make(next, as: Bridge.types[unqualified] != nil ? unqualified : name)
        }
    }
}

/// A Swish function as a Swift closure.
@_spi(Shell) public func bridgeClosure(_ shell: Interpreter, _ function: Value) -> ([Value]) throws -> Value {
    { arguments in try shell.call(function, with: arguments) }
}

/// Swish's values sort as `order(comparedTo:)` has it, so Swift's generic
/// algorithms that need Comparable elements work on them.
extension Value: @retroactive Comparable {
    public static func < (lhs: Value, rhs: Value) -> Bool {
        lhs.order(comparedTo: rhs) == .orderedAscending
    }
}
