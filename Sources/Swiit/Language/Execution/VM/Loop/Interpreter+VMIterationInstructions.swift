import Foundation

// Executing the instructions that begin a `for` and read its elements.

extension Interpreter {
    func executeIteration(
        _ instruction: Instruction.Iteration,
        _ cursor: inout VMCursor,
        _ stack: VMStack
    ) throws {
        let regs = stack.base + cursor.base
        let base = cursor.base
        switch instruction {
        case .rangeStart(let op, let counter, let lower, let upper):
            let range = try intRange(op, regs[Int(lower)], regs[Int(upper)])
            let registers = stack.base + base
            VMStack.put(.int(range.lowerBound), at: registers + Int(counter))
            VMStack.put(.int(range.upperBound), at: registers + Int(counter) + 1)
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
        case .iterationMismatch(let element):
            throw RuntimeError(
                "a \(stack.base[base + Int(element)].typeName) doesn't fit this 'for' pattern"
            )
        }
    }
}
