import Foundation

// The instructions for the members of structs, instances, lists and strings that are not the common
// path of the loop, so that they are not in it: they change registers and `pc`, never the frame.

extension Interpreter {
    func executeMemberInstruction(
        _ instruction: Instruction,
        _ cursor: inout VMCursor,
        _ stack: VMStack
    ) throws {
        var regs = stack.base + cursor.base
        switch instruction {
        case .fastMember(let kind, let dst, let receiver, let argument, let offset):
            if let result = try fastMember(kind, regs, receiver, argument) {
                regs[Int(dst)] = result
                cursor.pc += Int(offset)
            }
        case .fastGlobalMember(let kind, let dst, let global, let argument, let offset):
            if let result = try fastGlobalMember(
                kind,
                cursor.code.globalTable[Int(global)].takeUnretainedValue(),
                cursor.function,
                cursor.code,
                regs[Int(argument)]
            ) {
                regs = stack.base + cursor.base
                regs[Int(dst)] = result
                cursor.pc += Int(offset)
            }
        case .assignGlobalMember(
            let global,
            let siteIndex,
            let op,
            let value,
            let offset
        ):
            if try setGlobalMember(
                cursor.code.globalTable[Int(global)].takeUnretainedValue(),
                cursor.code.members[Int(siteIndex)],
                cursor.function,
                cursor.code,
                (op, regs[Int(value)])
            ) {
                cursor.pc += Int(offset)
            }
        case .assignMember(let local, let siteIndex, let op, let value, let offset):
            if setMember(
                cursor.code.members[Int(siteIndex)],
                &regs[Int(local)],
                op,
                regs[Int(value)]
            ) {
                cursor.pc += Int(offset)
            }
        case .assignSelfMember(let cell, let siteIndex, let op, let value, let offset):
            if case .object(let object) = regs[Int(cell)].storage,
                let cell = object as? Binding.Cell,
                setMember(
                    cursor.code.members[Int(siteIndex)],
                    in: cell,
                    op,
                    regs[Int(value)]
                )
            {
                cursor.pc += Int(offset)
            }
        case .callBridged(let dst, let siteIndex, let receiver, let arguments):
            let value = try callBridged(
                cursor.code.bridgedSites[Int(siteIndex)],
                receiver: receiver == Register.max ? nil : regs[Int(receiver)],
                arguments: cursor.base + Int(arguments)
            )
            regs = stack.base + cursor.base
            regs[Int(dst)] = value
        case .interpolate(let dst, let siteIndex, let first):
            var text = ""
            for piece in cursor.code.strings[Int(siteIndex)].pieces {
                switch piece {
                case .text(let literal): text += literal
                case .value(let index): text += try describing(regs[Int(first) + index])
                }
            }
            regs = stack.base + cursor.base
            regs[Int(dst)] = .string(text)
        default:
            try executeElementInstruction(instruction, &cursor, stack)
        }
    }

    /// `executeMemberInstruction` for the elements of lists and dictionaries.
    func executeElementInstruction(
        _ instruction: Instruction,
        _ cursor: inout VMCursor,
        _ stack: VMStack
    ) throws {
        let regs = stack.base + cursor.base
        switch instruction {
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
        default:
            try executeValueInstruction(instruction, &cursor, stack)
        }
    }

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
            preconditionFailure("not a value instruction")
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
