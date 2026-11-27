import Foundation

// The instructions for the members of structs, instances, lists and strings that are not the common
// path of the loop, so that they are not in it: they change registers and `pc`, never the frame.

/// The registers and offsets an `iterateNextPair` names.
private struct PairOperands {
    let iterator: Register
    let variable: Register
    let site: UInt32
    let exit: Int32
    let skip: Int32
}

extension Interpreter {
    func executeMemberInstruction(
        _ instruction: Instruction,
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
        case .assignMember(let local, let siteIndex, let op, let value, let offset):
            if setMember(
                cursor.code.members[Int(siteIndex)],
                &regs[Int(local)],
                op,
                regs[Int(value)]
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
        case .callBridged(let dst, let siteIndex, let receiver, let arguments):
            let value = try callBridged(
                cursor.code.bridgedSites[Int(siteIndex)],
                receiver: receiver == Register.max ? nil : regs[Int(receiver)],
                arguments: cursor.base + Int(arguments)
            )
            regs = stack.base + cursor.base
            regs[Int(dst)] = value
        case .interpolate(let dst, let siteIndex, let first):
            var text = ""
            for piece in cursor.code.strings[Int(siteIndex)].pieces {
                switch piece {
                case .text(let literal): text += literal
                case .value(let index): text += try describing(regs[Int(first) + index])
                }
            }
            regs = stack.base + cursor.base
            regs[Int(dst)] = .string(text)
        default:
            try executeElementInstruction(instruction, &cursor, stack)
        }
    }

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

    /// `executeMemberInstruction` for the instructions that make a value of others, or ask what a value
    /// is.
    func executeValueInstruction(
        _ instruction: Instruction,
        _ cursor: inout VMCursor,
        _ stack: VMStack
    ) throws {
        let regs = stack.base + cursor.base
        switch instruction {
        case .makeList(let dst, let first, let count):
            regs[Int(dst)] = .list(takeValues(regs + Int(first), count: Int(count)))
        case .makeDictionary(let dst, let first, let count):
            let pairs = takeValues(regs + Int(first), count: Int(count) * 2)
            var dictionary: [Value: Value] = [:]
            for index in 0..<Int(count) { dictionary[pairs[index * 2]] = pairs[index * 2 + 1] }
            regs[Int(dst)] = .dictionary(dictionary)
        case .makeTuple(let dst, let site, let first):
            let labels = cursor.code.tuples[Int(site)]
            let values = takeValues(regs + Int(first), count: labels.count)
            var record = Value.Record()
            for (index, label) in labels.enumerated() {
                record[label ?? String(index)] = values[index]
            }
            regs[Int(dst)] = Value(record: record)
        case .assignPath(let local, let site, let keys, let value, let offset):
            if try assignPath(
                cursor.code.paths[Int(site)],
                local: cursor.base + Int(local),
                keys: cursor.base + Int(keys),
                value: cursor.base + Int(value),
                on: stack
            ) {
                cursor.pc += Int(offset)
            }
        case .index(let dst, let base, let key):
            let value = try readIndex(regs[Int(base)], key: regs[Int(key)])
            stack.base[cursor.base + Int(dst)] = value
        case .dictionaryValue(let dst, let base, let key, let offset):
            guard case .dictionary(let dictionary) = regs[Int(base)].storage else {
                throw RuntimeError("'default:' goes with a dictionary")
            }
            if let found = dictionary[regs[Int(key)]] {
                regs[Int(dst)] = found
                cursor.pc += Int(offset)
            }
        case .requireValue(let src, let message):
            if regs[Int(src)] == .nothing { throw RuntimeError(cursor.code.names[Int(message)]) }
        case .describe(let dst, let src, let type):
            let text = try describing(regs[Int(src)], type: cursor.code.types[Int(type)])
            stack.base[cursor.base + Int(dst)] = .string(text)
        case .cast(let dst, let src, let type, let kind):
            let value = regs[Int(src)]
            let expected = cursor.code.types[Int(type)]
            let converted = conform(value, to: expected)
            let result: Value
            switch kind {
            case .conditional: result = converted ?? .nothing
            case .check: result = .bool(converted != nil)
            case .upcast: result = converted ?? value
            case .forced:
                guard let converted else {
                    throw RuntimeError("'as!' failed: a \(value.typeName) isn't a \(expected)")
                }
                result = converted
            }
            stack.base[cursor.base + Int(dst)] = result
        default:
            try executeControlInstruction(instruction, &cursor, stack)
        }
    }

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

    /// `executeMemberInstruction` for what looks a name up or leaves a piece to the tree evaluator, which
    /// first has the scope of `self` made in the frame of a method.
    func executeEvaluationInstruction(
        _ instruction: Instruction,
        _ cursor: inout VMCursor,
        _ stack: VMStack
    ) throws {
        let (function, code, base) = (cursor.function, cursor.code, cursor.base)
        switch instruction {
        case .loadVariable(let dst, let name):
            ensureSelfScope(function, code, base: base, on: stack)
            let value = try evaluate(.variable(code.names[Int(name)]))
            stack.base[base + Int(dst)] = value
        case .evaluate(let dst, let expression):
            ensureSelfScope(function, code, base: base, on: stack)
            let value = try evaluate(code.expressions[Int(expression)])
            stack.base[base + Int(dst)] = value
        case .evaluateTree(let dst, let node):
            ensureSelfScope(function, code, base: base, on: stack)
            let value = try runTree(code.trees[Int(node)], base: base, on: stack)
            stack.base[base + Int(dst)] = value
        case .runTree(let node):
            ensureSelfScope(function, code, base: base, on: stack)
            _ = try runTree(code.trees[Int(node)], base: base, on: stack)
        case .conform(let dst, let src, let type):
            let value = stack.base[base + Int(src)]
            let expected = code.types[Int(type)]
            guard let conforming = conform(value, to: expected) else {
                throw RuntimeError("expected \(expected), not \(value.typeName)")
            }
            stack.base[base + Int(dst)] = conforming
        case .assignByName(let site, let value):
            ensureSelfScope(function, code, base: base, on: stack)
            var assignment = code.assignments[Int(site)]
            assignment.value = .literal(stack.base[base + Int(value)])
            try assign(assignment)
        case .iterationMismatch(let element):
            throw RuntimeError(
                "a \(stack.base[base + Int(element)].typeName) doesn't fit this 'for' pattern"
            )
        case .derefWeak(let register):
            let slot = base + Int(register)
            if case .object(let reference as WeakReference) = stack.base[slot].storage {
                stack.base[slot] = reference.target.map { .object($0) } ?? .nothing
            }
        case .makeClosure(let dst, let site):
            ensureSelfScope(function, code, base: base, on: stack)
            let made = try makeClosure(code.closures[Int(site)], stack.base + base)
            stack.base[base + Int(dst)] = made
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
        default:
            preconditionFailure("not an evaluation instruction")
        }
    }

    /// `iterateNextPair`: the next key and value of a dictionary kept as two lists go where the names
    /// are; the next element of anything else goes into `variable`, for the destructuring after it.
    private func nextPair(
        _ operands: PairOperands,
        _ cursor: inout VMCursor,
        _ stack: VMStack
    ) throws {
        let (iterator, variable, site) = (operands.iterator, operands.variable, operands.site)
        let (exit, skip) = (operands.exit, operands.skip)
        var regs = stack.base + cursor.base
        let held = regs[Int(iterator)].storage
        if case .list(let items) = held {
            guard case .int(let index) = regs[Int(iterator) + 2].storage, index < items.count
            else {
                regs[Int(iterator)] = .nothing
                regs[Int(iterator) + 3] = .nothing
                cursor.pc += Int(exit)
                return
            }
            regs[Int(iterator) + 2] = .int(index + 1)
            if case .list(let values) = regs[Int(iterator) + 3].storage {
                for target in cursor.code.destructures[Int(site)].targets {
                    regs[Int(target.register)] = target.position == 0 ? items[index] : values[index]
                }
                cursor.pc += Int(skip)
            } else {
                regs[Int(variable)] = items[index]
            }
            return
        }
        guard case .object(let object) = held, let iteration = object as? IterationBox else {
            throw RuntimeError("a for lost its iterator")
        }
        let element = try iteration.next()
        regs = stack.base + cursor.base
        guard let element else {
            cursor.pc += Int(exit)
            return
        }
        regs[Int(variable)] = element
    }

    /// The values of the `count` registers at `first`, which are left holding nothing: they were made
    /// for this, and a collection that is changed later must not find them holding it.
    private func takeValues(_ first: UnsafeMutablePointer<Value>, count: Int) -> [Value] {
        (0..<count)
            .map { index in
                let value = first[index]
                first[index] = .nothing
                return value
            }
    }
}
