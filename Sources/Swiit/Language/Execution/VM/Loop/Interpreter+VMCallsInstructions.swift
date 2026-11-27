import Foundation

// Executing the instructions for bridged calls, inout arguments and failable initializers.

extension Interpreter {
    func executeCalls(
        _ instruction: Instruction.Calls,
        _ cursor: inout VMCursor,
        _ stack: VMStack
    ) throws {
        var regs = stack.base + cursor.base
        let base = cursor.base
        switch instruction {
        case .callBridged(let dst, let siteIndex, let receiver, let arguments):
            let value = try callBridged(
                cursor.code.bridgedSites[Int(siteIndex)],
                receiver: receiver == Register.max ? nil : regs[Int(receiver)],
                arguments: cursor.base + Int(arguments)
            )
            regs = stack.base + cursor.base
            regs[Int(dst)] = value
        case .inoutOutputs(let first, let count):
            task.inoutOutputs = (0..<Int(count)).map { stack.base[base + Int(first) + $0] }
        case .takeInout(let dst, let index):
            let outputs = task.inoutOutputs
            stack.base[base + Int(dst)] =
                Int(index) < outputs.count ? outputs[Int(index)] : .nothing
        case .finishInout:
            task.inoutOutputs = []
        case .failInit(let register):
            if register == Register.max || stack.base[base + Int(register)] == .nothing {
                task.failedInit = true
            }
        }
    }
}
