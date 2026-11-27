import Foundation

// Executing the instructions that match values to patterns.

extension Interpreter {
    func executePatterns(
        _ instruction: Instruction.Patterns,
        _ cursor: inout VMCursor,
        _ stack: VMStack
    ) throws {
        var regs = stack.base + cursor.base
        switch instruction {
        case .match(let patternIndex, let value, let fail):
            let site = cursor.code.patterns[Int(patternIndex)]
            var bindings: [String: Binding] = [:]
            let matched = try match(site.pattern, regs[Int(value)], into: &bindings)
            regs = stack.base + cursor.base
            if matched {
                for (name, register) in site.slots {
                    regs[Int(register)] = bindings[name]?.value ?? .nothing
                }
            } else {
                cursor.pc += Int(fail)
            }
        case .destructure(let site, let value, let offset):
            let site = cursor.code.destructures[Int(site)]
            if case .tuple(let tuple) = regs[Int(value)].storage, tuple.record.count == site.arity {
                for target in site.targets {
                    regs[Int(target.register)] = tuple.record.value(atPosition: target.position)
                }
                cursor.pc += Int(offset)
            }
        case .jumpIfWhereFalse(let condition, let offset):
            guard case .bool(let truth) = regs[Int(condition)].storage else {
                throw RuntimeError(
                    "a case's where must be a Bool, not \(regs[Int(condition)].typeName)"
                )
            }
            if !truth { cursor.pc += Int(offset) }
        case .noMatch(let value):
            let subject = regs[Int(value)]
            let shown = subject.description.isEmpty ? subject.typeName : subject.description
            throw RuntimeError("switch over \(shown) matched no case; add one, or a default")
        }
    }
}
