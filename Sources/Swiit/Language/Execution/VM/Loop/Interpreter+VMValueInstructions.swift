import Foundation

// The instructions that make values from registers: literals of collections, casts, descriptions, and
// changes through paths.

extension Interpreter {
    /// `executeMemberInstruction` for the instructions that make a value of others, or ask what a value
    /// is.
    func executeValueInstruction(
        _ instruction: Instruction,
        _ cursor: inout VMCursor,
        _ stack: VMStack
    ) throws {
        let regs = stack.base + cursor.base
        switch instruction {
        case .makeList(let dst, let first, let count):
            regs[Int(dst)] = .list(takeValues(regs + Int(first), count: Int(count)))
        case .appendValues(let local, let first, let count):
            var slot = regs[Int(local)]
            regs[Int(local)] = .nothing
            defer { stack.base[cursor.base + Int(local)] = slot }
            if case .list(var items) = slot.storage {
                slot = .nothing
                for index in 0..<Int(count) {
                    items.append(regs[Int(first) + index])
                    regs[Int(first) + index] = .nothing
                }
                slot = .list(items)
            } else {
                try applyInPlace(
                    .add,
                    &slot,
                    .list(takeValues(regs + Int(first), count: Int(count)))
                )
            }
        case .makeDictionary(let dst, let first, let count):
            let pairs = takeValues(regs + Int(first), count: Int(count) * 2)
            var dictionary: [Value: Value] = [:]
            for index in 0..<Int(count) { dictionary[pairs[index * 2]] = pairs[index * 2 + 1] }
            regs[Int(dst)] = .dictionary(dictionary)
        case .makeTuple(let dst, let site, let first):
            let labels = cursor.code.tuples[Int(site)]
            let values = takeValues(regs + Int(first), count: labels.count)
            var record = Value.Record()
            for (index, label) in labels.enumerated() {
                record[label ?? String(index)] = values[index]
            }
            regs[Int(dst)] = Value(record: record)
        case .assignPath(let local, let site, let keys, let value, let offset):
            if try assignPath(
                cursor.code.paths[Int(site)],
                local: cursor.base + Int(local),
                keys: cursor.base + Int(keys),
                value: cursor.base + Int(value),
                on: stack
            ) {
                cursor.pc += Int(offset)
            }
        case .index(let dst, let base, let key):
            let value = try readIndex(regs[Int(base)], key: regs[Int(key)])
            stack.base[cursor.base + Int(dst)] = value
        case .dictionaryValue(let dst, let base, let key, let offset):
            guard case .dictionary(let dictionary) = regs[Int(base)].storage else {
                throw RuntimeError("'default:' goes with a dictionary")
            }
            if let found = dictionary[regs[Int(key)]] {
                regs[Int(dst)] = found
                cursor.pc += Int(offset)
            }
        case .requireValue(let src, let message):
            if regs[Int(src)] == .nothing { throw RuntimeError(cursor.code.names[Int(message)]) }
        case .describe(let dst, let src, let type):
            let text = try describing(regs[Int(src)], type: cursor.code.types[Int(type)])
            stack.base[cursor.base + Int(dst)] = .string(text)
        case .cast(let dst, let src, let type, let kind):
            let value = regs[Int(src)]
            let expected = cursor.code.types[Int(type)]
            let converted = conform(value, to: expected)
            let result: Value
            switch kind {
            case .conditional: result = converted ?? .nothing
            case .check: result = .bool(converted != nil)
            case .upcast: result = converted ?? value
            case .forced:
                guard let converted else {
                    throw RuntimeError("'as!' failed: a \(value.typeName) isn't a \(expected)")
                }
                result = converted
            }
            stack.base[cursor.base + Int(dst)] = result
        default:
            try executeControlInstruction(instruction, &cursor, stack)
        }
    }

    /// The values of the `count` registers at `first`, which are left holding nothing: they were made
    /// for this, and a collection that is changed later must not find them holding it.
    private func takeValues(_ first: UnsafeMutablePointer<Value>, count: Int) -> [Value] {
        (0..<count)
            .map { index in
                let value = first[index]
                first[index] = .nothing
                return value
            }
    }
}
