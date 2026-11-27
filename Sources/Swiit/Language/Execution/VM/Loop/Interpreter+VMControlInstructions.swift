import Foundation

// The instructions for matching patterns, iterating, and the errors of a `switch`, a `throw`, a `catch`
// and a `guard`.

extension Interpreter {
    /// `executeMemberInstruction` for matching a pattern, and the errors a `switch`, a `throw`, a
    /// `catch` and a `guard` give.
    func executeControlInstruction(
        _ instruction: Instruction,
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
        case .iterate(let dst, let sequence, let awaiting):
            // A list, and the entries of a dictionary, are read by position; the rest by an iterator.
            let source = regs[Int(sequence)]
            if !awaiting, case .list = source.storage {
                regs[Int(dst)] = source
                regs[Int(dst) + 2] = .int(0)
            } else if !awaiting, case .dictionary(let dictionary) = source.storage {
                regs[Int(dst)] = .list(dictionaryEntries(dictionary))
                regs[Int(dst) + 2] = .int(0)
            } else {
                let iteration = try makeIteration(source, awaiting: awaiting)
                stack.base[cursor.base + Int(dst)] = .object(iteration)
            }
        case .iteratePairs(let dst, let sequence):
            // The keys and the values of a dictionary are kept as two lists, read by position.
            let source = regs[Int(sequence)]
            regs[Int(dst) + 3] = .nothing
            if case .dictionary(let dictionary) = source.storage {
                let (keys, values) = dictionaryColumns(dictionary)
                regs[Int(dst)] = .list(keys)
                regs[Int(dst) + 3] = .list(values)
                regs[Int(dst) + 2] = .int(0)
            } else if case .list = source.storage {
                regs[Int(dst)] = source
                regs[Int(dst) + 2] = .int(0)
            } else {
                let iteration = try makeIteration(source, awaiting: false)
                stack.base[cursor.base + Int(dst)] = .object(iteration)
            }
        case .iterateNextPair(let iterator, let variable, let site, let exit, let skip):
            let operands = PairOperands(
                iterator: iterator,
                variable: variable,
                site: site,
                exit: exit,
                skip: skip
            )
            try nextPair(operands, &cursor, stack)
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
        default:
            try executeEvaluationInstruction(instruction, &cursor, stack)
        }
    }
}
