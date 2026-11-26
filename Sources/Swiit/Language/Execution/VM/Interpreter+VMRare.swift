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
            preconditionFailure("not a member instruction")
        }
    }
}
