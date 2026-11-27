import Foundation

// The instructions for the elements of lists and dictionaries that are not the common path of the loop.

extension Interpreter {
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
}
