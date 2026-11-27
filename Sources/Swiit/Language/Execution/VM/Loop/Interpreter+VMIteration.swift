import Foundation

// What a `for` reads its elements from: a list by position, a dictionary's keys and values, or an
// iterator.

// safe: it is used only holding the interpreter lock, by the task that made it
/// A collection being read by a `for`, in a register: what to ask for the next element.
final class IterationBox: LanguageObject, @unchecked Sendable {
    let next: () throws -> Value?

    init(_ next: @escaping () throws -> Value?) { self.next = next }

    var typeName: String { "Iterator" }
    var memberNames: [String] { [] }
    func member(_ name: String) -> Value? { nil }
    var description: String { "an iterator" }
}

/// The registers and offsets an `iterateNextPair` names.
struct PairOperands {
    let iterator: Register
    let variable: Register
    let site: UInt32
    let exit: Int32
    let skip: Int32
}

extension Interpreter {
    /// `iterateNextPair`: the next key and value of a dictionary kept as two lists go where the names
    /// are; the next element of anything else goes into `variable`, for the destructuring after it.
    func nextPair(
        _ operands: PairOperands,
        _ cursor: inout VMCursor,
        _ stack: VMStack
    ) throws {
        let (iterator, variable, site) = (operands.iterator, operands.variable, operands.site)
        let (exit, skip) = (operands.exit, operands.skip)
        var regs = stack.base + cursor.base
        let held = regs[Int(iterator)].storage
        if case .list(let items) = held {
            guard case .int(let index) = regs[Int(iterator) + 2].storage, index < items.count
            else {
                regs[Int(iterator)] = .nothing
                regs[Int(iterator) + 3] = .nothing
                cursor.pc += Int(exit)
                return
            }
            regs[Int(iterator) + 2] = .int(index + 1)
            if case .list(let values) = regs[Int(iterator) + 3].storage {
                for target in cursor.code.destructures[Int(site)].targets {
                    regs[Int(target.register)] = target.position == 0 ? items[index] : values[index]
                }
                cursor.pc += Int(skip)
            } else {
                regs[Int(variable)] = items[index]
            }
            return
        }
        guard case .object(let object) = held, let iteration = object as? IterationBox else {
            throw RuntimeError("a for lost its iterator")
        }
        let element = try iteration.next()
        regs = stack.base + cursor.base
        guard let element else {
            cursor.pc += Int(exit)
            return
        }
        regs[Int(variable)] = element
    }
}

extension Interpreter {
    /// The entries of a dictionary as the tuples a `for` reads (`key`, `value`), in the order they are
    /// shown in, which is the same every run.
    func dictionaryEntries(_ dictionary: [Value: Value]) -> [Value] {
        dictionary.sortedForDisplay.map { entry in
            var record = Value.Record(typeRef: nil, capacity: 2)
            record.appendDistinct("key", entry.key)
            record.appendDistinct("value", entry.value)
            return Value(record: record)
        }
    }

    /// The keys of a dictionary and, at the same positions, its values, in the order the entries are
    /// shown in.
    func dictionaryColumns(_ dictionary: [Value: Value]) -> (keys: [Value], values: [Value]) {
        dictionary.columnsForDisplay
    }

    /// What `for x in value` reads: the elements of a collection, the characters of a string, the
    /// entries of a dictionary, a task group's results, or what the value's own iterator gives.
    func makeIteration(_ value: Value, awaiting: Bool) throws -> IterationBox {
        if let read = Interpreter.taskGroupReader(of: value) { return IterationBox(read) }
        if case .dictionary(let dictionary) = value.storage {
            var entries = dictionaryEntries(dictionary).makeIterator()
            return IterationBox { entries.next() }
        }
        if case .string(let text) = value.storage {
            var characters = text.makeIterator()
            return IterationBox { characters.next().map { .string(String($0)) } }
        }
        if var items = Interpreter.items(of: value) { return IterationBox { items.next() } }
        if let next = try iterator(of: value, awaiting: awaiting) { return IterationBox(next) }
        throw RuntimeError("can't iterate over \(value.typeName)")
    }
}
