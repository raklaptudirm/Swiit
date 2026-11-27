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
        let stop = task.cancellation.word
        let callers = stack.callers
        let entryDepth = callers.count
        unowned(unsafe) var function = entry
        unowned(unsafe) var code = entryCode
        var base = entryBase
        var pc = 0
        var statement: Int32 = -1
        var regs = stack.base + base
        var instructions = code.program
        var functionRef = Unmanaged.passUnretained(function)
        var codeRef = Unmanaged.passUnretained(code)
        let observer = host.didFinishStatement
        while true {
            do {
                while true {
                    let instruction = instructions[pc]
                    pc += 1
                    switch instruction {
                    case .step(let range):
                        statement = range
                        try tick(stop, run)
                        regs = stack.base + base
                    case .at(let range):
                        statement = range
                    case .tick:
                        try tick(stop, run)
                        regs = stack.base + base
                    case .finished(let value, let isOptionalTry):
                        if let observer, observesStatements {
                            let shown = value == Register.max ? nil : regs[Int(value)]
                            observer(shown, isOptionalTry && shown == .nothing)
                        }
                    case .loadConstant(let dst, let constant):
                        VMStack.put(code.constants[Int(constant)], at: regs + Int(dst))
                    case .move(let dst, let src):
                        VMStack.put(regs[Int(src)], at: regs + Int(dst))
                    case .clear(let first, let count):
                        for index in Int(first)..<(Int(first) + Int(count)) {
                            regs[index] = .nothing
                        }
                    case .binary(let op, let dst, let lhs, let rhs):
                        if let x = VMStack.integer(at: regs + Int(lhs)),
                            let y = VMStack.integer(at: regs + Int(rhs)),
                            let result = try Value.commonIntegerOperation(op, x, y)
                        {
                            VMStack.put(result, at: regs + Int(dst))
                            continue
                        }
                        let value = try apply(op, regs[Int(lhs)], regs[Int(rhs)])
                        regs = stack.base + base
                        regs[Int(dst)] = value
                    case .binaryImmediate(let op, let dst, let lhs, let value):
                        if let x = VMStack.integer(at: regs + Int(lhs)),
                            let result = try Value.commonIntegerOperation(op, x, Int(value))
                        {
                            VMStack.put(result, at: regs + Int(dst))
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
                            VMStack.put(regs[Int(value)], at: regs + Int(local))
                            continue
                        }
                        if case .int(let x) = regs[Int(local)].storage,
                            case .int(let y) = regs[Int(value)].storage
                        {
                            let result = try Value.integerArithmetic(op, x, y)
                            regs = stack.base + base
                            VMStack.put(result, at: regs + Int(local))
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
                        if let x = VMStack.integer(at: regs + Int(lhs)) {
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
                        VMStack.put(.int(range.lowerBound), at: regs + Int(counter))
                        VMStack.put(.int(range.upperBound), at: regs + Int(counter) + 1)
                    case .rangeNext(let counter, let variable, let exit):
                        guard case .int(let next) = regs[Int(counter)].storage,
                            case .int(let end) = regs[Int(counter) + 1].storage, next < end
                        else {
                            pc += Int(exit)
                            continue
                        }
                        VMStack.put(.int(next), at: regs + Int(variable))
                        VMStack.put(.int(next + 1), at: regs + Int(counter))
                    case .jumpIfNil(let register, let offset):
                        if regs[Int(register)] == .nothing { pc += Int(offset) }
                    case .caughtTaken:
                        stack.caught.removeLast()
                    case .rethrow:
                        throw stack.caught.removeLast()
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
                        unowned(unsafe) let site =
                            codeRef._withUnsafeGuaranteedRef {
                                $0.callSiteTable[Int(siteIndex)]
                            }
                            .takeUnretainedValue()
                        let argumentBase = base + Int(arguments)
                        // What the site called last time, while the names are as they were.
                        unowned(unsafe) var callee = function
                        unowned(unsafe) var calleeCode = code
                        var calleeRef = functionRef
                        var calleeCodeRef = codeRef
                        var sharesScopes = false
                        var found = false
                        if site.cachedVersion == scopeVersion,
                            site.cachedCaller
                                == functionRef._withUnsafeGuaranteedRef { ObjectIdentifier($0) }
                        {
                            calleeRef = site.cachedCallee.unsafelyUnwrapped
                            calleeCodeRef = site.cachedCode.unsafelyUnwrapped
                            callee = calleeRef.takeUnretainedValue()
                            calleeCode = calleeCodeRef.takeUnretainedValue()
                            sharesScopes = site.cachedSharesScopes
                            found = true
                        } else if let target = vmTarget(of: site, from: function) {
                            (callee, calleeCode, sharesScopes) =
                                (target.function, target.code, target.sharesScopes)
                            calleeRef = .passUnretained(callee)
                            calleeCodeRef = .passUnretained(calleeCode)
                            found = true
                            // Not cached: a call that leaves out parameters places its arguments.
                            if site.lastDefaults, let mapping = site.lastMapping {
                                try placeArguments(mapping, of: callee, at: argumentBase)
                                regs = stack.base + base
                            }
                        }
                        if found {
                            // The scopes are the caller's own and stay so: nothing to save or set.
                            let sameScopes =
                                sharesScopes && codeRef._withUnsafeGuaranteedRef { $0.isPlain }
                            guard task.callDepth < maxCallDepth else {
                                throw RuntimeError("maximum call depth (\(maxCallDepth)) exceeded")
                            }
                            try tick(stop, run)
                            let facts = calleeCodeRef._withUnsafeGuaranteedRef { $0.facts }
                            for index in 0..<facts.parameterCount
                            where !facts.kinds[index].accepts(at: stack.base + argumentBase + index)
                            {
                                try checkArguments(
                                    of: callee,
                                    calleeCode,
                                    at: argumentBase,
                                    on: stack
                                )
                                break
                            }
                            stack.push(
                                VMCaller(
                                    codeRef: codeRef,
                                    functionRef: functionRef,
                                    calleeRef: calleeRef,
                                    pc: pc,
                                    base: base,
                                    statement: statement,
                                    destination: base + Int(dst),
                                    sameScopes: sameScopes
                                ),
                                scopes: sameScopes
                                    || task.scopes.count == function.captured.count
                                    ? nil : task.scopes
                            )
                            stack.ensure(argumentBase + facts.frameSize)
                            stack.top = argumentBase + facts.frameSize
                            if !sameScopes { setScopes(of: callee, from: function, task) }
                            task.callDepth += 1
                            function = callee
                            code = calleeCode
                            functionRef = calleeRef
                            codeRef = calleeCodeRef
                            instructions = facts.program
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
                            if let value = try constructOrCallLookingUp(made, &cursor, stack) {
                                regs = stack.base + base
                                regs[Int(dst)] = value
                            } else {
                                (function, code) = (cursor.function, cursor.code)
                                (base, pc, statement) = (cursor.base, cursor.pc, cursor.statement)
                                instructions = code.program
                                (functionRef, codeRef) = cursor.refs
                                regs = stack.base + base
                            }
                        }
                    case .iterateNext(let iterator, let variable, let exit):
                        // A list is read by position, from the register that holds it.
                        if case .list(let items) = regs[Int(iterator)].storage {
                            guard case .int(let index) = regs[Int(iterator) + 2].storage,
                                index < items.count
                            else {
                                regs[Int(iterator)] = .nothing
                                pc += Int(exit)
                                continue
                            }
                            VMStack.put(items[index], at: regs + Int(variable))
                            VMStack.put(.int(index + 1), at: regs + Int(iterator) + 2)
                            continue
                        }
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
                            try tick(stop, run)
                            try checkKinds(callee, calleeCode, at: argumentBase, on: stack)
                            stack.push(
                                VMCaller(
                                    code: code,
                                    function: function,
                                    callee: callee,
                                    pc: pc,
                                    base: base,
                                    statement: statement,
                                    destination: base + Int(dst)
                                ),
                                scopes: task.scopes.count == function.captured.count
                                    ? nil : task.scopes
                            )
                            stack.ensure(argumentBase + calleeCode.frameSize)
                            stack.top = argumentBase + calleeCode.frameSize
                            setScopes(of: callee, from: function, task)
                            task.callDepth += 1
                            function = callee
                            code = calleeCode
                            functionRef = .passUnretained(callee)
                            codeRef = .passUnretained(calleeCode)
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
                    case .storeCell(let box, let src):
                        try cell(regs[Int(box)]).value = regs[Int(src)]
                    case .assignCell(let box, let op, let value):
                        let held = try cell(regs[Int(box)])
                        var slot = held.value
                        held.value = .nothing
                        defer { held.value = slot }
                        try applyInPlace(op, &slot, regs[Int(value)])
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
                            (function, code) = (cursor.function, cursor.code)
                            (base, pc, statement) = (cursor.base, cursor.pc, cursor.statement)
                            instructions = code.program
                            (functionRef, codeRef) = cursor.refs
                            regs = stack.base + base
                        }
                    case .callMethod(
                        let dst,
                        let siteIndex,
                        let receiver,
                        let arguments,
                        let offset
                    ):
                        // A method of a struct that does not change it, found by an earlier call at this
                        // site: a frame like a function's, with the receiver in the register of `self`.
                        let own = codeRef._withUnsafeGuaranteedRef { $0.facts }
                        unowned(unsafe) let methodSite = own.methods[Int(siteIndex)]
                            .takeUnretainedValue()
                        if methodSite.fastVersion == scopeVersion,
                            methodSite.fastCaller
                                == functionRef._withUnsafeGuaranteedRef({
                                    ObjectIdentifier($0)
                                }),
                            methodSite.receiverFits(at: regs + Int(receiver)),
                            methodSite.globalFits(version: scopeVersion),
                            task.scopes.count == own.capturedCount,
                            task.callDepth < maxCallDepth
                        {
                            let calleeRef = methodSite.fastFunction.unsafelyUnwrapped
                            let calleeCodeRef = methodSite.fastCode.unsafelyUnwrapped
                            let facts = calleeCodeRef._withUnsafeGuaranteedRef { $0.facts }
                            let argumentBase = base + Int(arguments)
                            var fits = true
                            for index in 0..<facts.parameterCount
                            where !facts.kinds[index].accepts(at: stack.base + argumentBase + index)
                            {
                                fits = false
                                break
                            }
                            if fits {
                                try tick(stop, run)
                                let receiverValue = regs[Int(receiver)]
                                var record = VMCaller(
                                    codeRef: codeRef,
                                    functionRef: functionRef,
                                    calleeRef: calleeRef,
                                    pc: pc + Int(offset),
                                    base: base,
                                    statement: statement,
                                    destination: base + Int(dst),
                                    sameScopes: true
                                )
                                var selfValue = receiverValue
                                if methodSite.fastChangesReceiver {
                                    selfValue = stack.moveReceiver(
                                        at: base + Int(receiver),
                                        of: methodSite.global?.cell,
                                        inPlace: facts.inPlaceSelf >= 0
                                    )
                                    record.isMethod = true
                                }
                                stack.push(record)
                                stack.ensure(argumentBase + facts.frameSize)
                                stack.top = argumentBase + facts.frameSize
                                task.callDepth += 1
                                (functionRef, codeRef) = (calleeRef, calleeCodeRef)
                                function = functionRef._withUnsafeGuaranteedRef { $0 }
                                code = codeRef._withUnsafeGuaranteedRef { $0 }
                                instructions = facts.program
                                base = argumentBase
                                pc = 0
                                statement = -1
                                regs = stack.base + base
                                if facts.selfRegister >= 0 {
                                    VMStack.put(selfValue, at: regs + facts.selfRegister)
                                }
                                continue
                            }
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
                            receiver: receiver,
                            arguments: arguments,
                            offset: offset
                        )
                        if try enterMethod(code.methods[Int(siteIndex)], operands, &cursor, stack) {
                            (function, code) = (cursor.function, cursor.code)
                            (base, pc, statement) = (cursor.base, cursor.pc, cursor.statement)
                            instructions = code.program
                            (functionRef, codeRef) = cursor.refs
                            regs = stack.base + base
                        }
                    case .loadGlobal(let dst, let siteIndex):
                        unowned(unsafe) let site = code.globalTable[Int(siteIndex)]
                            .takeUnretainedValue()
                        if site.version == scopeVersion,
                            site.function
                                == functionRef._withUnsafeGuaranteedRef { ObjectIdentifier($0) },
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
                            site.function
                                == functionRef._withUnsafeGuaranteedRef { ObjectIdentifier($0) },
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
                    case .returnValue, .returnNothing:
                        let result: Value
                        if case .returnValue(let register) = instruction {
                            result = regs[Int(register)]
                        } else {
                            result = .nothing
                        }
                        // The common return, to a frame of this loop with no task started: what `leave`
                        // does, without building a cursor.
                        if callers.count > entryDepth, task.children.isEmpty {
                            let finished = codeRef._withUnsafeGuaranteedRef { $0.facts }
                            if finished.inPlaceSelf >= 0 {
                                stack.leftSelf = regs[finished.inPlaceSelf]
                            }
                            VMStack.clear(regs, count: finished.frameSize)
                            task.callDepth -= 1
                            let caller = callers.removeLast()
                            defer { caller.releaseCallee() }
                            functionRef = caller.functionRef
                            codeRef = caller.codeRef
                            function = functionRef._withUnsafeGuaranteedRef { $0 }
                            code = codeRef._withUnsafeGuaranteedRef { $0 }
                            let resumed = codeRef._withUnsafeGuaranteedRef { $0.facts }
                            instructions = resumed.program
                            base = caller.base
                            pc = caller.pc
                            statement = caller.statement
                            if caller.hasScopes {
                                task.scopes = stack.savedScopes.removeLast()
                            } else if !caller.sameScopes {
                                caller.calleeRef._withUnsafeGuaranteedRef {
                                    setScopes(of: function, from: $0, task)
                                }
                            }
                            stack.top = base + resumed.frameSize
                            var made: Value?
                            if caller.isMethod {
                                made = try finishMethod(stack.methodExits.removeLast(), on: stack)
                            }
                            let conforming: Value
                            if let made {
                                conforming = made
                            } else if finished.returnKind.accepts(result) {
                                conforming = result
                            } else {
                                conforming = try caller.calleeRef._withUnsafeGuaranteedRef {
                                    try conformed(result, to: $0)
                                }
                            }
                            VMStack.put(conforming, at: stack.base + caller.destination)
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
                            (function, code) = (cursor.function, cursor.code)
                            (base, pc, statement) = (cursor.base, cursor.pc, cursor.statement)
                            instructions = code.program
                            (functionRef, codeRef) = cursor.refs
                            regs = stack.base + base
                            throw error
                        }
                        if let left { return left }
                        (function, code) = (cursor.function, cursor.code)
                        (base, pc, statement) = (cursor.base, cursor.pc, cursor.statement)
                        instructions = code.program
                        (functionRef, codeRef) = cursor.refs
                        regs = stack.base + base
                    case .members, .collections, .conversions, .patterns, .iteration, .errors,
                        .fallback, .captures, .calls:
                        var cursor = VMCursor(
                            function: function,
                            code: code,
                            base: base,
                            pc: pc,
                            statement: statement
                        )
                        try executeHandedOff(instruction, &cursor, stack)
                        pc = cursor.pc
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
                (function, code) = (cursor.function, cursor.code)
                (base, pc, statement) = (cursor.base, cursor.pc, cursor.statement)
                instructions = code.program
                (functionRef, codeRef) = cursor.refs
                regs = stack.base + base
            }
        }
    }

    // swiftlint:enable cyclomatic_complexity function_body_length
}
