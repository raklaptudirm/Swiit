import Foundation

// Closures a native body calls that only compute: `{ $0 + 1 }`, `{ $0 % 2 == 0 }`, `{ $0.x > $1.x }`.
// They are run by a loop of their own, which has no frame to push, no handler to look up and no error
// to unwind, because it does nothing that has to be undone: where anything is not what it does itself
// (an operand of another kind, an overflow, a division by zero, a field that is not stored), it says so,
// and the call is made as any call is, from the start, which gives the error or the value it would.

extension Interpreter {
    /// The call of a leaf closure with the arguments `write` puts in its first registers: its value, or
    /// nil, with nothing changed, where the call is to be made the long way.
    @inline(__always)
    func leafCall(
        _ function: Function,
        _ code: Code,
        count: Int,
        _ write: (UnsafeMutablePointer<Value>) -> Void
    ) throws -> Value? {
        let stack = task.vm
        let base = stack.top
        stack.ensure(base + code.frameSize)
        let registers = stack.base + base
        write(registers)
        var result: Value?
        if (0..<count).allSatisfy({ code.kindTable[$0].accepts(at: registers + $0) }) {
            result = runLeaf(code, at: registers)
        }
        VMStack.clear(registers, count: code.frameSize)
        // What a call does besides running: its step, and what the host asks of the function called.
        guard let result, code.returnKind.accepts(result),
            task.callDepth < task.run.maxCallDepth
        else { return nil }
        try checkInterrupt()
        if task.lastCallee !== function { task.lastCallee = function }
        vmLeafCalls += 1
        return result
    }

    /// Runs the code of a leaf closure over registers holding its arguments; nil where it must be left
    /// to the loop.
    private func runLeaf(_ code: Code, at registers: UnsafeMutablePointer<Value>) -> Value? {
        let program = code.facts.program
        var pc = 0
        while true {
            let instruction = program[pc]
            pc += 1
            switch instruction {
            case .move(let dst, let src):
                registers[Int(dst)] = registers[Int(src)]
            case .loadConstant(let dst, let constant):
                registers[Int(dst)] = code.constants[Int(constant)]
            case .binary(let op, let dst, let lhs, let rhs):
                guard let value = Value.leafOperation(op, registers[Int(lhs)], registers[Int(rhs)])
                else {
                    return nil
                }
                registers[Int(dst)] = value
            case .binaryImmediate(let op, let dst, let lhs, let immediate):
                guard let value = Value.leafOperation(op, registers[Int(lhs)], .int(Int(immediate)))
                else {
                    return nil
                }
                registers[Int(dst)] = value
            case .unary(let op, let dst, let src):
                guard let value = leafUnary(op, registers[Int(src)]) else { return nil }
                registers[Int(dst)] = value
            case .loadMember(let dst, let base, let name, _):
                guard let field = storedField(code.names[Int(name)], of: registers[Int(base)])
                else {
                    return nil
                }
                registers[Int(dst)] = field
            case .returnValue(let register):
                return registers[Int(register)]
            case .returnNothing:
                return .nothing
            case .at:
                continue
            default:
                switch leafJump(instruction, registers) {
                case .stay: continue
                case .by(let offset): pc += offset
                case .giveUp: return nil
                }
            }
        }
    }

    private enum Jump {
        /// The next instruction runs.
        case stay
        /// The one `offset` after the next runs.
        case by(Int)
        /// It is not an instruction the leaf loop runs, or what it reads is not what it expects.
        case giveUp
    }

    /// What a jump instruction of a leaf does.
    private func leafJump(
        _ instruction: Instruction,
        _ registers: UnsafeMutablePointer<Value>
    ) -> Jump {
        switch instruction {
        case .jump(let offset):
            return .by(Int(offset))
        case .shortCircuit(let op, let register, let offset):
            guard let truth = registers[Int(register)].leafBool else { return .giveUp }
            return truth == (op == .or) ? .by(Int(offset)) : .stay
        case .needBool(_, let register):
            return registers[Int(register)].leafBool == nil ? .giveUp : .stay
        case .jumpIfFalse(let condition, let offset):
            guard let truth = registers[Int(condition)].leafBool else { return .giveUp }
            return truth ? .stay : .by(Int(offset))
        case .jumpIfTrue(let condition, let offset):
            guard let truth = registers[Int(condition)].leafBool else { return .giveUp }
            return truth ? .by(Int(offset)) : .stay
        case .jumpUnlessCompare(let op, let lhs, let immediate, let offset):
            guard
                let truth = Value.leafOperation(op, registers[Int(lhs)], .int(Int(immediate)))?
                    .leafBool
            else { return .giveUp }
            return truth ? .stay : .by(Int(offset))
        case .jumpIfNil(let register, let offset):
            return registers[Int(register)] == .nothing ? .by(Int(offset)) : .stay
        case .jumpIfNotNil(let register, let offset):
            return registers[Int(register)] != .nothing ? .by(Int(offset)) : .stay
        default:
            return .giveUp
        }
    }

    /// `op value` of a Bool or a number, when nothing goes wrong; nil otherwise.
    private func leafUnary(_ op: UnaryOperator, _ value: Value) -> Value? {
        switch (op, value.storage) {
        case (.not, .bool(let truth)): .bool(!truth)
        case (.negate, .int(let number)) where number != Int.min: .int(-number)
        case (.negate, .double(let number)): .double(-number)
        default: nil
        }
    }

}

extension Value {
    /// `lhs op rhs` where both are of one plain kind and nothing goes wrong; nil otherwise, where the
    /// call is made the long way, which gives the error.
    fileprivate static func leafOperation(
        _ op: BinaryOperator,
        _ lhs: Value,
        _ rhs: Value
    ) -> Value? {
        (try? plainOperation(op, lhs, rhs)) ?? nil
    }

    /// The Bool it is, if it is one.
    fileprivate var leafBool: Bool? {
        if case .bool(let truth) = storage { truth } else { nil }
    }
}
