import Foundation

// Running compiled code: the loop that executes a function's instructions (`Docs/vm.md`).

extension Interpreter {
    /// The code the VM runs for `function`, compiled the first time it is asked for; nil when the
    /// function stays on the tree evaluator.
    func compiled(_ function: Function) -> Code? {
        switch function.vmCode {
        case .code(let code): return code
        case .unsupported: return nil
        case .untried:
            switch CodeCompiler.compile(function, bridged: bridged) {
            case .success(let code):
                function.vmCode = .code(code)
                return code
            case .failure(let unsupported):
                function.vmCode = .unsupported(unsupported.reason)
                guard case .swiit = function.body else { return nil }
                vmFallbacks.append("\(function.name ?? "a closure"): \(unsupported.reason)")
                return nil
            }
        }
    }

    // swiftlint:disable cyclomatic_complexity function_body_length - one case for each instruction
    /// The instructions of one run: the entry frame, and the frames it calls, which are pushed on
    /// `stack` and run by this loop and not by Swift's stack.
    func execute(
        _ entry: Function,
        _ entryCode: Code,
        base entryBase: Int,
        on stack: VMStack
    ) throws -> Value {
        let task = self.task
        let run = task.run
        let maxCallDepth = run.maxCallDepth
        let entryDepth = stack.callers.count
        unowned(unsafe) var function = entry
        unowned(unsafe) var code = entryCode
        var base = entryBase
        var pc = 0
        var statement: Int32 = -1
        var regs = stack.base + base
        var instructions = code.program
        let observing = host.didFinishStatement != nil

        while true {
            do {
                while true {
                    let instruction = instructions[pc]
                    pc += 1
                    switch instruction {
                    case .step(let range):
                        statement = range
                        try tick(task, run)
                        regs = stack.base + base
                    case .at(let range):
                        statement = range
                    case .tick:
                        try tick(task, run)
                        regs = stack.base + base
                    case .finished(let index, let value):
                        if observing, observesStatements {
                            finished(
                                code.statements[Int(index)],
                                value == Register.max ? nil : regs[Int(value)]
                            )
                        }
                    case .loadConstant(let dst, let constant):
                        regs[Int(dst)] = code.constants[Int(constant)]
                    case .move(let dst, let src):
                        regs[Int(dst)] = regs[Int(src)]
                    case .loadVariable(let dst, let name):
                        let value = try evaluate(.variable(code.names[Int(name)]))
                        regs = stack.base + base
                        regs[Int(dst)] = value
                    case .evaluate(let dst, let expression):
                        let value = try evaluate(code.expressions[Int(expression)])
                        regs = stack.base + base
                        regs[Int(dst)] = value
                    case .clear(let first, let count):
                        for index in Int(first)..<(Int(first) + Int(count)) {
                            regs[index] = .nothing
                        }
                    case .conform(let dst, let src, let type):
                        let value = regs[Int(src)]
                        let expected = code.types[Int(type)]
                        guard let conforming = conform(value, to: expected) else {
                            throw RuntimeError("expected \(expected), not \(value.typeName)")
                        }
                        regs = stack.base + base
                        regs[Int(dst)] = conforming
                    case .binary(let op, let dst, let lhs, let rhs):
                        if case .int(let x) = regs[Int(lhs)].storage,
                            case .int(let y) = regs[Int(rhs)].storage,
                            let result = try Interpreter.arithmetic(op, x, y)
                        {
                            regs[Int(dst)] = result
                            continue
                        }
                        let value = try apply(op, regs[Int(lhs)], regs[Int(rhs)])
                        regs = stack.base + base
                        regs[Int(dst)] = value
                    case .binaryImmediate(let op, let dst, let lhs, let value):
                        if case .int(let x) = regs[Int(lhs)].storage,
                            let result = try Interpreter.arithmetic(op, x, Int(value))
                        {
                            regs[Int(dst)] = result
                            continue
                        }
                        let value = try apply(op, regs[Int(lhs)], .int(Int(value)))
                        regs = stack.base + base
                        regs[Int(dst)] = value
                    case .unary(let op, let dst, let src):
                        let value = try apply(op, regs[Int(src)])
                        regs = stack.base + base
                        regs[Int(dst)] = value
                    case .shortCircuit(let op, let register, let offset):
                        guard case .bool(let truth) = regs[Int(register)].storage else {
                            throw RuntimeError(
                                "'\(op.rawValue)' needs Bool operands, not \(regs[Int(register)].typeName)"
                            )
                        }
                        if truth == (op == .or) { pc += Int(offset) }
                    case .needBool(let op, let register):
                        guard case .bool = regs[Int(register)].storage else {
                            throw RuntimeError(
                                "'\(op.rawValue)' needs Bool operands, not \(regs[Int(register)].typeName)"
                            )
                        }
                    case .jumpIfNotNil(let register, let offset):
                        if regs[Int(register)] != .nothing { pc += Int(offset) }
                    case .assign(let local, let op, let value):
                        guard let op else {
                            regs[Int(local)] = regs[Int(value)]
                            continue
                        }
                        if case .int(let x) = regs[Int(local)].storage,
                            case .int(let y) = regs[Int(value)].storage
                        {
                            let result = try integerArithmetic(op, x, y)
                            regs = stack.base + base
                            regs[Int(local)] = result
                            continue
                        }
                        // What a place changes in place is moved out while it does, so that a
                        // collection is not copied.
                        var slot = regs[Int(local)]
                        let operand = regs[Int(value)]
                        regs[Int(local)] = .nothing
                        defer {
                            regs = stack.base + base
                            regs[Int(local)] = slot
                        }
                        try applyInPlace(op, &slot, operand)
                    case .jump(let offset):
                        pc += Int(offset)
                    case .jumpIfFalse(let condition, let offset):
                        guard case .bool(let truth) = regs[Int(condition)].storage else {
                            throw RuntimeError(
                                "condition must be a Bool, not \(regs[Int(condition)].typeName)"
                            )
                        }
                        if !truth { pc += Int(offset) }
                    case .jumpUnlessCompare(let op, let lhs, let value, let offset):
                        let truth: Bool
                        if case .int(let x) = regs[Int(lhs)].storage {
                            let y = Int(value)
                            switch op {
                            case .less: truth = x < y
                            case .lessEqual: truth = x <= y
                            case .greater: truth = x > y
                            case .greaterEqual: truth = x >= y
                            case .equal: truth = x == y
                            default: truth = x != y
                            }
                        } else {
                            let result = try apply(op, regs[Int(lhs)], .int(Int(value)))
                            regs = stack.base + base
                            guard case .bool(let held) = result.storage else {
                                throw RuntimeError(
                                    "condition must be a Bool, not \(result.typeName)"
                                )
                            }
                            truth = held
                        }
                        if !truth { pc += Int(offset) }
                    case .jumpIfTrue(let condition, let offset):
                        guard case .bool(let truth) = regs[Int(condition)].storage else {
                            throw RuntimeError(
                                "condition must be a Bool, not \(regs[Int(condition)].typeName)"
                            )
                        }
                        if truth { pc += Int(offset) }
                    case .rangeStart(let op, let counter, let lower, let upper):
                        let range = try intRange(op, regs[Int(lower)], regs[Int(upper)])
                        regs = stack.base + base
                        regs[Int(counter)] = .int(range.lowerBound)
                        regs[Int(counter) + 1] = .int(range.upperBound)
                    case .rangeNext(let counter, let variable, let exit):
                        guard case .int(let next) = regs[Int(counter)].storage,
                            case .int(let end) = regs[Int(counter) + 1].storage, next < end
                        else {
                            pc += Int(exit)
                            continue
                        }
                        regs[Int(variable)] = .int(next)
                        regs[Int(counter)] = .int(next + 1)
                    case .match(let patternIndex, let value, let fail):
                        let site = code.patterns[Int(patternIndex)]
                        var bindings: [String: Binding] = [:]
                        let matched = try match(site.pattern, regs[Int(value)], into: &bindings)
                        regs = stack.base + base
                        if matched {
                            for (name, register) in site.slots {
                                regs[Int(register)] = bindings[name]?.value ?? .nothing
                            }
                        } else {
                            pc += Int(fail)
                        }
                    case .jumpIfWhereFalse(let condition, let offset):
                        guard case .bool(let truth) = regs[Int(condition)].storage else {
                            throw RuntimeError(
                                "a case's where must be a Bool, not \(regs[Int(condition)].typeName)"
                            )
                        }
                        if !truth { pc += Int(offset) }
                    case .noMatch(let value):
                        let subject = regs[Int(value)]
                        let shown =
                            subject.description.isEmpty ? subject.typeName : subject.description
                        throw RuntimeError(
                            "switch over \(shown) matched no case; add one, or a default"
                        )
                    case .jumpIfNil(let register, let offset):
                        if regs[Int(register)] == .nothing { pc += Int(offset) }
                    case .throwValue(let register):
                        let value = regs[Int(register)]
                        throw RuntimeError(
                            (try? describing(value)) ?? value.description,
                            thrown: value
                        )
                    case .caughtTaken:
                        stack.caught.removeLast()
                    case .rethrow:
                        throw stack.caught.removeLast()
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
                    case .jumpIfNotDeferred(let register, let bit, let offset):
                        if case .int(let marks) = regs[Int(register)].storage,
                            marks & (1 << Int(bit)) != 0
                        {
                            continue
                        }
                        pc += Int(offset)
                    case .quietBegin:
                        stack.quiet.append(observesStatements)
                        observesStatements = false
                    case .quietEnd:
                        observesStatements = stack.quiet.removeLast()
                    case .call(let dst, let siteIndex, let arguments):
                        unowned(unsafe) let site = code.callSiteTable[Int(siteIndex)]
                            .takeUnretainedValue()
                        let argumentBase = base + Int(arguments)
                        // What the site called last time, while the names are as they were.
                        unowned(unsafe) var callee = function
                        unowned(unsafe) var calleeCode = code
                        var sharesScopes = false
                        var found = false
                        if site.cachedVersion == scopeVersion,
                            site.cachedCaller == ObjectIdentifier(function)
                        {
                            callee = site.cachedCallee.unsafelyUnwrapped.takeUnretainedValue()
                            calleeCode = site.cachedCode.unsafelyUnwrapped.takeUnretainedValue()
                            sharesScopes = site.cachedSharesScopes
                            found = true
                        } else if let target = vmTarget(of: site, from: function) {
                            (callee, calleeCode, sharesScopes) =
                                (target.function, target.code, target.sharesScopes)
                            found = true
                            // Not cached: a call that leaves out parameters places its arguments.
                            if site.lastDefaults, let mapping = site.lastMapping {
                                try placeArguments(mapping, of: callee, at: argumentBase)
                                regs = stack.base + base
                            }
                        }
                        if found {
                            // The scopes are the caller's own and stay so: nothing to save or set.
                            let sameScopes = sharesScopes && code.isPlain
                            guard task.callDepth < maxCallDepth else {
                                throw RuntimeError("maximum call depth (\(maxCallDepth)) exceeded")
                            }
                            try tick(task, run)
                            try checkArguments(of: callee, calleeCode, at: argumentBase)
                            stack.callers.append(
                                VMCaller(
                                    code: code,
                                    function: function,
                                    callee: callee,
                                    pc: pc,
                                    base: base,
                                    statement: statement,
                                    destination: base + Int(dst),
                                    scopes: sameScopes
                                        || task.scopes.count == function.captured.count
                                        ? nil : task.scopes,
                                    sameScopes: sameScopes
                                )
                            )
                            stack.ensure(argumentBase + calleeCode.frameSize)
                            stack.top = argumentBase + calleeCode.frameSize
                            if !sameScopes { setScopes(of: callee, from: function, task) }
                            task.callDepth += 1
                            function = callee
                            code = calleeCode
                            instructions = calleeCode.program
                            base = argumentBase
                            pc = 0
                            statement = -1
                            regs = stack.base + base
                        } else {
                            var cursor = VMCursor(
                                function: function,
                                code: code,
                                base: base,
                                pc: pc,
                                statement: statement
                            )
                            let made = ConstructCall(
                                site: site,
                                dst: dst,
                                argumentBase: argumentBase
                            )
                            if let value = try constructOrCall(made, &cursor, stack) {
                                regs = stack.base + base
                                regs[Int(dst)] = value
                            } else {
                                (function, code, base, pc, statement) =
                                    (
                                        cursor.function, cursor.code, cursor.base, cursor.pc,
                                        cursor.statement
                                    )
                                instructions = code.program
                                regs = stack.base + base
                            }
                        }
                    case .evaluateTree(let dst, let node):
                        let value = try runTree(code.trees[Int(node)], base: base, on: stack)
                        regs = stack.base + base
                        regs[Int(dst)] = value
                    case .runTree(let node):
                        _ = try runTree(code.trees[Int(node)], base: base, on: stack)
                        regs = stack.base + base
                    case .iterate(let dst, let sequence, let awaiting):
                        let iteration = try makeIteration(regs[Int(sequence)], awaiting: awaiting)
                        regs = stack.base + base
                        regs[Int(dst)] = .object(iteration)
                    case .iterateNext(let iterator, let variable, let exit):
                        guard case .object(let object) = regs[Int(iterator)].storage,
                            let iteration = object as? IterationBox
                        else { throw RuntimeError("a for lost its iterator") }
                        let element = try iteration.next()
                        regs = stack.base + base
                        guard let element else {
                            pc += Int(exit)
                            continue
                        }
                        regs[Int(variable)] = element
                    case .iterationMismatch(let element):
                        throw RuntimeError(
                            "a \(regs[Int(element)].typeName) doesn't fit this 'for' pattern"
                        )
                    case .callValue(let dst, let calleeRegister, let siteIndex, let arguments):
                        let site = code.callSites[Int(siteIndex)]
                        let argumentBase = base + Int(arguments)
                        if let (callee, calleeCode) = vmTarget(
                            ofValue: regs[Int(calleeRegister)],
                            arguments: site.labels.count
                        ) {
                            guard task.callDepth < maxCallDepth else {
                                throw RuntimeError("maximum call depth (\(maxCallDepth)) exceeded")
                            }
                            try tick(task, run)
                            try checkArguments(of: callee, calleeCode, at: argumentBase)
                            stack.callers.append(
                                VMCaller(
                                    code: code,
                                    function: function,
                                    callee: callee,
                                    pc: pc,
                                    base: base,
                                    statement: statement,
                                    destination: base + Int(dst),
                                    scopes: task.scopes.count == function.captured.count
                                        ? nil : task.scopes
                                )
                            )
                            stack.ensure(argumentBase + calleeCode.frameSize)
                            stack.top = argumentBase + calleeCode.frameSize
                            setScopes(of: callee, from: function, task)
                            task.callDepth += 1
                            function = callee
                            code = calleeCode
                            instructions = calleeCode.program
                            base = argumentBase
                            pc = 0
                            statement = -1
                            regs = stack.base + base
                            // A closure that names `self` has the cell of it, which it captured, in a register.
                            if let register = code.selfRegister, let binding = lookup("self") {
                                regs[Int(register)] = .object(binding.cell)
                            }
                        } else {
                            let callee = regs[Int(calleeRegister)]
                            let value = try evaluateCall(site, .literal(callee), argumentBase)
                            regs = stack.base + base
                            regs[Int(dst)] = value
                        }
                    case .box(let register):
                        regs[Int(register)] = .object(Binding.Cell(regs[Int(register)]))
                    case .loadCell(let dst, let box):
                        regs[Int(dst)] = try cell(regs[Int(box)]).value
                    case .derefWeak(let register):
                        if case .object(let reference as WeakReference) = regs[Int(register)]
                            .storage
                        {
                            regs[Int(register)] = reference.target.map { .object($0) } ?? .nothing
                        }
                    case .storeCell(let box, let src):
                        try cell(regs[Int(box)]).value = regs[Int(src)]
                    case .assignCell(let box, let op, let value):
                        let held = try cell(regs[Int(box)])
                        var slot = held.value
                        held.value = .nothing
                        defer { held.value = slot }
                        try applyInPlace(op, &slot, regs[Int(value)])
                        regs = stack.base + base
                    case .makeClosure(let dst, let site):
                        let made = try makeClosure(code.closures[Int(site)], regs)
                        regs = stack.base + base
                        regs[Int(dst)] = made
                    case .fastMember, .fastGlobalMember, .assignMember, .assignGlobalMember,
                        .assignSelfMember, .callBridged, .interpolate, .assignElement,
                        .assignGlobalElement:
                        var cursor = VMCursor(
                            function: function,
                            code: code,
                            base: base,
                            pc: pc,
                            statement: statement
                        )
                        try executeMemberInstruction(instruction, &cursor, stack)
                        pc = cursor.pc
                        regs = stack.base + base
                    case .loadMember(let dst, let baseRegister, let name, let siteIndex):
                        if let field = storedField(
                            code.names[Int(name)],
                            of: regs[Int(baseRegister)]
                        ) {
                            regs[Int(dst)] = field
                            continue
                        }
                        var cursor = VMCursor(
                            function: function,
                            code: code,
                            base: base,
                            pc: pc,
                            statement: statement
                        )
                        let operands = CallOperands(
                            dst: dst,
                            receiver: baseRegister,
                            arguments: Register(code.frameSize),
                            offset: 0
                        )
                        let read = try readMember(
                            code.methods[Int(siteIndex)],
                            code.names[Int(name)],
                            operands,
                            &cursor,
                            stack
                        )
                        if let read {
                            regs = stack.base + base
                            regs[Int(dst)] = read
                        } else {
                            // A computed property's getter, which is a frame above this one's registers.
                            (function, code, base, pc, statement) =
                                (
                                    cursor.function, cursor.code, cursor.base, cursor.pc,
                                    cursor.statement
                                )
                            instructions = code.program
                            regs = stack.base + base
                        }
                    case .callMethod(
                        let dst,
                        let siteIndex,
                        let receiver,
                        let arguments,
                        let offset
                    ):
                        var cursor = VMCursor(
                            function: function,
                            code: code,
                            base: base,
                            pc: pc,
                            statement: statement
                        )
                        let operands = CallOperands(
                            dst: dst,
                            receiver: receiver,
                            arguments: arguments,
                            offset: offset
                        )
                        if try enterMethod(code.methods[Int(siteIndex)], operands, &cursor, stack) {
                            (function, code, base, pc, statement) =
                                (
                                    cursor.function, cursor.code, cursor.base, cursor.pc,
                                    cursor.statement
                                )
                            instructions = code.program
                            regs = stack.base + base
                        }
                    case .loadGlobal(let dst, let siteIndex):
                        unowned(unsafe) let site = code.globalTable[Int(siteIndex)]
                            .takeUnretainedValue()
                        if site.version == scopeVersion,
                            site.function == ObjectIdentifier(function),
                            let cell = site.cell
                        {
                            let value = cell.value
                            if case .object(is WeakReference) = value.storage {
                            } else {
                                regs[Int(dst)] = value
                                continue
                            }
                        }
                        let value = try globalValue(site, function, code)
                        regs = stack.base + base
                        regs[Int(dst)] = value
                    case .assignGlobal(let global, let assignmentIndex, let value):
                        unowned(unsafe) let site = code.globalTable[Int(global)]
                            .takeUnretainedValue()
                        if site.version == scopeVersion,
                            site.function == ObjectIdentifier(function),
                            site.isMutable, let cell = site.cell,
                            setNumber(
                                in: cell,
                                code.assignments[Int(assignmentIndex)].op,
                                to: regs[Int(value)]
                            )
                        {
                            continue
                        }
                        let assignment = code.assignments[Int(assignmentIndex)]
                        try assignGlobal(site, assignment, regs[Int(value)], function, code)
                        regs = stack.base + base
                    case .assignByName(let site, let value):
                        var assignment = code.assignments[Int(site)]
                        assignment.value = .literal(regs[Int(value)])
                        try assign(assignment)
                        regs = stack.base + base
                    case .inoutOutputs(let first, let count):
                        task.inoutOutputs = (0..<Int(count)).map { regs[Int(first) + $0] }
                    case .takeInout(let dst, let index):
                        let outputs = task.inoutOutputs
                        regs[Int(dst)] = Int(index) < outputs.count ? outputs[Int(index)] : .nothing
                    case .finishInout:
                        task.inoutOutputs = []
                    case .failInit(let register):
                        if register == Register.max || regs[Int(register)] == .nothing {
                            task.failedInit = true
                        }
                    case .returnValue, .returnNothing:
                        let result: Value
                        if case .returnValue(let register) = instruction {
                            result = regs[Int(register)]
                        } else {
                            result = .nothing
                        }
                        // The common return, to a frame of this loop with no task started: what `leave`
                        // does, without building a cursor.
                        if stack.callers.count > entryDepth, task.children.isEmpty {
                            unowned(unsafe) let finishedCode = code
                            VMStack.clear(regs, count: finishedCode.frameSize)
                            task.callDepth -= 1
                            let caller = stack.callers.removeLast()
                            function = caller.function
                            code = caller.code
                            instructions = code.program
                            base = caller.base
                            pc = caller.pc
                            statement = caller.statement
                            if let own = caller.scopes {
                                task.scopes = own
                            } else if !caller.sameScopes {
                                setScopes(of: function, from: caller.callee, task)
                            }
                            stack.top = base + code.frameSize
                            var made: Value?
                            if caller.isMethod {
                                made = try finishMethod(stack.methodExits.removeLast(), on: stack)
                            }
                            let conforming =
                                try made
                                ?? (finishedCode.returnKind.accepts(result)
                                    ? result : conformed(result, to: caller.callee))
                            stack.base[caller.destination] = conforming
                            regs = stack.base + base
                            continue
                        }
                        var cursor = VMCursor(
                            function: function,
                            code: code,
                            base: base,
                            pc: pc,
                            statement: statement
                        )
                        let left: Value?
                        do {
                            left = try leave(
                                with: result,
                                &cursor,
                                entryDepth: entryDepth,
                                on: stack
                            )
                        } catch {
                            // The frame is left before what finishes it fails: the error is the caller's.
                            (function, code, base, pc, statement) =
                                (
                                    cursor.function, cursor.code, cursor.base, cursor.pc,
                                    cursor.statement
                                )
                            instructions = code.program
                            regs = stack.base + base
                            throw error
                        }
                        if let left { return left }
                        (function, code, base, pc, statement) =
                            (cursor.function, cursor.code, cursor.base, cursor.pc, cursor.statement)
                        instructions = code.program
                        regs = stack.base + base
                    }
                }
            } catch {
                var cursor = VMCursor(
                    function: function,
                    code: code,
                    base: base,
                    pc: pc,
                    statement: statement
                )
                try unwind(error, &cursor, entryDepth: entryDepth, on: stack)
                (function, code, base, pc, statement) =
                    (cursor.function, cursor.code, cursor.base, cursor.pc, cursor.statement)
                instructions = code.program
                regs = stack.base + base
            }
        }
    }

    // swiftlint:enable cyclomatic_complexity function_body_length
}
