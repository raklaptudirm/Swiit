import Foundation

// Executing the instructions that make closures and read weak variables.

extension Interpreter {
    func executeCaptures(
        _ instruction: Instruction.Captures,
        _ cursor: inout VMCursor,
        _ stack: VMStack
    ) throws {
        let (function, code, base) = (cursor.function, cursor.code, cursor.base)
        switch instruction {
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
