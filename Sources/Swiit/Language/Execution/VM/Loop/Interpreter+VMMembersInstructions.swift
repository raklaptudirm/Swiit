import Foundation

// Executing the instructions for the stored fields of structs and instances.

extension Interpreter {
    func executeMembers(
        _ instruction: Instruction.Members,
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
        case .assignMember(let local, let siteIndex, let op, let value, let offset):
            if setMember(
                cursor.code.members[Int(siteIndex)],
                &regs[Int(local)],
                op,
                regs[Int(value)]
            ) {
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
        case .assignSelfMember(let cell, let siteIndex, let op, let value, let offset):
            // The register holds the cell of `self`, or, in a class's method, the instance.
            if case .object(let object) = regs[Int(cell)].storage {
                let site = cursor.code.members[Int(siteIndex)]
                var done = false
                if let cell = object as? Binding.Cell {
                    done = setMember(site, in: cell, op, regs[Int(value)])
                } else if object is ClassInstance {
                    var held = regs[Int(cell)]
                    done = setMember(site, &held, op, regs[Int(value)])
                }
                if done { cursor.pc += Int(offset) }
            }
        }
    }
}
