import Foundation

// Executing the instructions that make closures and read weak variables.

extension Interpreter {
    func executeCaptures(
        _ instruction: Instruction.Captures,
        _ cursor: inout VMCursor,
        _ stack: VMStack
    ) throws {
        let (function, code, base) = (cursor.function, cursor.code, cursor.base)
        let regs = stack.base + base
        switch instruction {
        case .box(let register):
            regs[Int(register)] = .object(Binding.Cell(regs[Int(register)]))
        case .loadCell(let dst, let box):
            regs[Int(dst)] = try cell(regs[Int(box)]).value
        case .storeCell(let box, let src):
            try cell(regs[Int(box)]).value = regs[Int(src)]
        case .assignCell(let box, let op, let value):
            let held = try cell(regs[Int(box)])
            var slot = held.value
            held.value = .nothing
            defer { held.value = slot }
            try applyInPlace(op, &slot, regs[Int(value)])
        case .makeClosure(let dst, let site):
            ensureSelfScope(function, code, base: base, on: stack)
            let made = try makeClosure(code.closures[Int(site)], stack.base + base)
            stack.base[base + Int(dst)] = made
        case .derefWeak(let register):
            let slot = base + Int(register)
            if case .object(let reference as WeakReference) = stack.base[slot].storage {
                stack.base[slot] = reference.target.map { .object($0) } ?? .nothing
            }
        }
    }
}
