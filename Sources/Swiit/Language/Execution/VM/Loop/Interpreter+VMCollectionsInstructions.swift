import Foundation

// Executing the instructions that make and change lists, dictionaries and tuples.

extension Interpreter {
    func executeCollections(
        _ instruction: Instruction.Collections,
        _ cursor: inout VMCursor,
        _ stack: VMStack
    ) throws {
        let regs = stack.base + cursor.base
        let base = cursor.base
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
        case .assignElement(let local, let keys, let hasDefault, let op, let value, let offset):
            let fallback = hasDefault ? regs[Int(keys) + 1] : nil
            if regs[Int(local)].setElement(regs[Int(keys)], fallback, op, regs[Int(value)]) {
                cursor.pc += Int(offset)
            }
        case .assignGlobalElement(
            let global,
            let keys,
            let hasDefault,
            let op,
            let value,
            let offset
        ):
            let site = cursor.code.globalTable[Int(global)].takeUnretainedValue()
            if !(site.version == scopeVersion && site.function == ObjectIdentifier(cursor.function))
            {
                findGlobal(site, cursor.function, cursor.code)
            }
            if site.isMutable, let cell = site.cell {
                // Taken out of the cell, so that it is changed where it is and not copied.
                var held = cell.value
                cell.value = .nothing
                let done = held.setElement(
                    regs[Int(keys)],
                    hasDefault ? regs[Int(keys) + 1] : nil,
                    op,
                    regs[Int(value)]
                )
                cell.value = held
                if done { cursor.pc += Int(offset) }
            }
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
