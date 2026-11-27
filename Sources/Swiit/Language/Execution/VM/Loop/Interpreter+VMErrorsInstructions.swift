import Foundation

// Executing the instructions for errors and the deferred blocks they run.

extension Interpreter {
    func executeErrors(
        _ instruction: Instruction.Errors,
        _ cursor: inout VMCursor,
        _ stack: VMStack
    ) throws {
        let regs = stack.base + cursor.base
        switch instruction {
        case .throwValue(let register):
            let value = regs[Int(register)]
            throw RuntimeError((try? describing(value)) ?? value.description, thrown: value)
        case .fatalize:
            let error = stack.caught.removeLast()
            guard let runtime = error as? RuntimeError else { throw error }
            throw FatalError(error: runtime)
        case .reportDeferred:
            report("error: \(stack.caught.removeLast())")
        case .guardCarriedOn:
            throw RuntimeError("guard's else carried on")
        case .deferMark(let register, let bit):
            if case .int(let marks) = regs[Int(register)].storage {
                regs[Int(register)] = .int(marks | (1 << Int(bit)))
            }
        }
    }
}
