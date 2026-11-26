import Foundation
import SystemPackage

extension FilePath: BridgedValue {}

/// A path as Swiit holds it: a FilePath.
func pathValue(_ path: String) -> Value {
    SwiftValue.make(FilePath(path), as: "FilePath")
}

/// What a record's field is that encoding loses: an enum is encoded as its
/// raw text and a path as an object, and Swiit holds them as what they are.
enum FieldKind {
    case enumeration(String)
    /// A Swift type held as it is, of this name: a `FilePath`, a `FileSize`.
    case boxed(String)
}

/// `lower...upper` or `lower..<upper`, of any values that compare.
func makeRange(_ op: BinaryOperator, _ lower: Value, _ upper: Value) throws -> Value {
    guard lower <= upper else {
        throw RuntimeError("range \(lower)\(op.rawValue)\(upper) has its bounds reversed")
    }
    if op == .closedRange {
        return SwiftValue.make(
            ClosedRange(uncheckedBounds: (lower: lower, upper: upper)),
            as: "ClosedRange"
        )
    }
    return SwiftValue.make(Range(uncheckedBounds: (lower: lower, upper: upper)), as: "Range")
}

extension Interpreter {
    /// A task group's items as they finish, which reading can throw on; nil for anything else.
    static func taskGroupReader(of value: Value) -> (() throws -> Value?)? {
        guard case .object(let box as SwiftValue) = value.storage,
            let group = box.value as? TaskGroupBox
        else {
            return nil
        }
        return { try group.next() }
    }

    /// The items of a list, or a Swift sequence Swiit
    /// holds (a host type's text) (a Set, a range of Ints, a dictionary's keys), one at a time,
    /// so a range of a billion never becomes a list; nil for anything else.
    static func items(of value: Value) -> AnyIterator<Value>? {
        switch value.storage {
        case .list(let items):
            return AnyIterator(items.makeIterator())
        case .object(let box as SwiftValue):
            if let range = box.value as? ClosedRange<Value> {
                guard case .int(let lower) = range.lowerBound.storage,
                    case .int(let upper) = range.upperBound.storage
                else {
                    return nil
                }
                return AnyIterator(IntegerIterator(next: lower, last: upper))
            }
            if let range = box.value as? Range<Value> {
                guard case .int(let lower) = range.lowerBound.storage,
                    case .int(let upper) = range.upperBound.storage
                else {
                    return nil
                }
                return AnyIterator(IntegerIterator(next: lower, last: upper - 1))
            }
            guard let sequence = box.value as? any Sequence else { return nil }
            return iterator(sequence)
        default:
            return nil
        }
    }

    /// The Ints from `next` to `last`, one at a time, as values.
    private struct IntegerIterator: IteratorProtocol {
        var upcoming: Int
        let last: Int
        var isDone = false

        init(next: Int, last: Int) {
            upcoming = next
            self.last = last
            isDone = next > last
        }

        mutating func next() -> Value? {
            guard !isDone else { return nil }
            let current = upcoming
            if current == last { isDone = true } else { upcoming += 1 }
            return .int(current)
        }
    }

    /// The values of a range of Ints, made all at once: what a member that takes a sequence and wants
    /// its elements (an `Array(0..<n)`, a `Set`) reads, without a generic iterator for each. Nil for
    /// anything else.
    static func integers(in value: Value) -> [Value]? {
        guard case .object(let box as SwiftValue) = value.storage else { return nil }
        if let range = box.value as? Range<Value>, case .int(let lower) = range.lowerBound.storage,
            case .int(let upper) = range.upperBound.storage
        {
            return (lower..<Swift.max(lower, upper)).map(Value.int)
        }
        if let range = box.value as? ClosedRange<Value>,
            case .int(let lower) = range.lowerBound.storage,
            case .int(let upper) = range.upperBound.storage, lower <= upper, upper < Int.max
        {
            return (lower...upper).map(Value.int)
        }
        return nil
    }

    /// A Swift sequence's elements as Swiit values, boxed by their type's name.
    static func iterator<S: Sequence>(_ sequence: S) -> AnyIterator<Value> {
        var iterator = sequence.makeIterator()
        return AnyIterator {
            guard let next = iterator.next() else { return nil }
            if let value = next as? Value { return value }
            // What Swiit has a value of its own for is that, not a box (a host type's lines are
            // Strings).
            if next is String || next is Int || next is Double || next is Bool {
                return Value(reflecting: next)
            }
            // By the name Swiit writes it with, without its module:
            // FilePath.Component, not SystemPackage.FilePath.Component.
            let name = String(reflecting: type(of: next))
            let unqualified = String(name.drop { $0 != "." }.dropFirst())
            return SwiftValue.make(
                next,
                as: Bridge.current[unqualified] != nil ? unqualified : name
            )
        }
    }
}

/// Swiit's values sort as `order(comparedTo:)` has it, so Swift's generic
/// algorithms that need Comparable elements work on them.
extension Value: Comparable {
    public static func < (lhs: Value, rhs: Value) -> Bool {
        switch (lhs.storage, rhs.storage) {
        case (.int(let x), .int(let y)): return x < y
        case (.double(let x), .double(let y)): return x < y
        default: break
        }
        // A type of the program's with its own `<` (Comparable) says which comes first.
        if lhs.isOfProgramsType, let interpreter = Waiting.host as? Interpreter,
            case .bool(let less)? = try? interpreter.userOperator("<", [lhs, rhs])?.storage
        {
            return less
        }
        return lhs.order(comparedTo: rhs) == .orderedAscending
    }
}

extension Value {
    /// A struct or class instance, which a program's `<` may order.
    fileprivate var isOfProgramsType: Bool {
        switch self.storage {
        case .structure: true
        case .object(let object): object is ClassInstance
        default: false
        }
    }
}
