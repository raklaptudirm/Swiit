import Foundation

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

extension Interpreter {
    /// Runs what the compiler left to the tree evaluator, over a frame holding the locals it
    /// mentions: each is moved out of its register into the frame (a collection is not copied that
    /// way, so changing it in place stays cheap), or shared when a closure keeps it in a cell, and
    /// moved back after, whatever happened.
    func runTree(_ node: TreeNode, base: Int, on stack: VMStack) throws -> Value {
        vmTreeRuns += 1
        let task = self.task
        let frame = task.spareFrames.popLast() ?? Frame(size: node.frameSize)
        frame.reset(size: node.frameSize)
        var moved: [Int] = []
        for local in node.locals {
            let index = base + Int(local.slot)
            if local.boxed, case .object(let object) = stack.base[index].storage,
                let cell = object as? Binding.Cell
            {
                frame.bind(
                    local.name,
                    Binding(cell: cell, mutable: local.mutable),
                    at: Int(local.slot)
                )
            } else {
                frame.bind(
                    local.name,
                    Binding(value: stack.base[index], mutable: local.mutable),
                    at: Int(local.slot)
                )
                stack.base[index] = .nothing
                moved.append(Int(local.slot))
            }
        }
        let saved = (task.frame, task.frameBase)
        task.frame = frame
        task.frameBase = task.scopes.count
        defer {
            for slot in moved {
                stack.base[base + slot] = frame.binding(at: slot)?.value ?? .nothing
            }
            frame.empty()
            task.spareFrames.append(frame)
            (task.frame, task.frameBase) = saved
        }
        switch node.source {
        case .expression(let expression): return try evaluate(expression)
        case .statement(let statement):
            try run(statement)
            return .nothing
        }
    }

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
