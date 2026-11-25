import Foundation

/// How a function body runs: on the tree evaluator, or compiled to `Code` and run by the VM where the
/// compiler handles it (`Docs/vm.md`). Both run the same checked program and give the same results.
enum Engine: Sendable {
    case tree
    case vm

    /// The engine a new interpreter starts with: the VM. Building with `-Xswiftc -DSWIIT_TREE_ENGINE`
    /// makes it the tree evaluator, which runs the test suites as the reference.
    static var initial: Engine {
        #if SWIIT_TREE_ENGINE
        .tree
        #else
        .vm
        #endif
    }
}

/// What the VM made of a function body, kept with the function.
enum VMCode {
    case untried
    case code(Code)
    /// It stays on the tree evaluator, for this reason.
    case unsupported(String)
}

extension Function {
    /// Whether the compiler may take this body: a function or method, or a closure with what it
    /// captured, whose parameters are taken as they come.
    var isCompilable: Bool {
        guard case .swiit(let program) = body else { return false }
        return program.frameSize != nil && !(name != nil && captured.count > 2)
    }
}

extension Interpreter {
    /// The code the VM runs for `function`, compiled the first time it is asked for; nil when the
    /// function stays on the tree evaluator.
    func compiled(_ function: Function) -> Code? {
        switch function.vmCode {
        case .code(let code): return code
        case .unsupported: return nil
        case .untried:
            switch CodeCompiler.compile(function) {
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

    /// Runs a function the VM has code for, called from the tree evaluator or from outside: the
    /// arguments are in `arguments`, and what it gives is the result, conformed to its return type.
    func runCompiled(
        _ function: Function,
        _ code: Code,
        with arguments: BindingTable,
        receiver: Receiver? = nil
    ) throws -> Value {
        let task = self.task
        let stack = task.vm
        let base = stack.top
        stack.ensure(base + code.frameSize)
        for (index, parameter) in function.parameters.enumerated() {
            stack.base[base + index] = arguments[parameter.name]?.value ?? .nothing
        }
        stack.top = base + code.frameSize
        let saved = (scopes: task.scopes, frame: task.frame, frameBase: task.frameBase)
        task.scopes = function.captured
        // A method has `self`, and a generic function its type parameters, in a scope of the call.
        var own: Scope?
        if receiver != nil || !code.isPlain {
            let made = Scope()
            openTypeParameters(of: function, arguments, in: made)
            if let receiver {
                made.bindings["self"] = Binding(
                    value: receiver.value,
                    mutable: receiver.mutable,
                    special: receiver.initializing ? .initializing : nil
                )
            }
            task.scopes.append(made)
            own = made
        }
        if let owner = function.owner { task.owners.append(owner) }
        if !code.isProgram { task.callDepth += 1 }
        task.frame = nil
        defer {
            if let receiver, let changed = own?.bindings["self"]?.value { receiver.value = changed }
            task.scopes = saved.scopes
            task.frame = saved.frame
            task.frameBase = saved.frameBase
            if function.owner != nil { task.owners.removeLast() }
            stack.top = base
        }
        let result = try execute(function, code, base: base, on: stack)
        return try conformed(result, to: function)
    }

    /// `result` as the function's return type says, or the error the tree evaluator gives.
    func conformed(_ result: Value, to function: Function) throws -> Value {
        guard let returnType = function.returnType else { return result }
        guard let conforming = conform(result, to: returnType) else {
            let what = result == .nothing ? "nothing" : result.typeName
            throw RuntimeError(
                "\(function.name ?? "closure") must return \(returnType), but returned \(what)"
            )
        }
        return conforming
    }

    /// What a frame does as it ends, however it ends: its registers are let go, its call is over, and
    /// the tasks it started are closed.
    func leaveFrame(_ function: Function, _ code: Code, base: Int, _ stack: VMStack) {
        for index in 0..<code.frameSize { stack.base[base + index] = .nothing }
        let task = self.task
        if !code.isProgram { task.callDepth -= 1 }
        if task.lastCallee !== function { task.lastCallee = function }
        if !task.children.isEmpty, let last = task.children.last, last.depth > task.callDepth {
            closeTasks(above: task.callDepth)
        }
    }

    /// Makes the scopes of `callee` the task's, which are those of `caller` already when both are
    /// functions of the global scopes: the task's scopes are always its running function's.
    func setScopes(of callee: Function, from caller: Function, _ task: TaskContext) {
        let wanted = callee.captured
        let current = caller.captured
        if task.scopes.count == current.count, wanted.count == current.count, wanted.count <= 2,
            wanted.isEmpty
                || (wanted[0] === current[0] && (wanted.count < 2 || wanted[1] === current[1]))
        {
            return
        }
        task.scopes = wanted
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
        let entryDepth = stack.callers.count
        var function = entry
        var code = entryCode
        var base = entryBase
        var pc = 0
        var statement: Int32 = -1
        var regs = stack.base + base
        var instructions = code.instructions
        let observing = host.didFinishStatement != nil

        while true {
            do {
                while true {
                    let instruction = instructions[pc]
                    pc += 1
                    switch instruction {
                    case .step(let range):
                        statement = range
                        try checkInterrupt()
                        regs = stack.base + base
                    case .at(let range):
                        statement = range
                    case .tick:
                        try checkInterrupt()
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
                            case .int(let y) = regs[Int(rhs)].storage
                        {
                            switch op {
                            case .add:
                                let (sum, overflow) = x.addingReportingOverflow(y)
                                guard !overflow else { throw RuntimeError("arithmetic overflow") }
                                regs[Int(dst)] = .int(sum)
                                continue
                            case .subtract:
                                let (difference, overflow) = x.subtractingReportingOverflow(y)
                                guard !overflow else { throw RuntimeError("arithmetic overflow") }
                                regs[Int(dst)] = .int(difference)
                                continue
                            case .multiply:
                                let (product, overflow) = x.multipliedReportingOverflow(by: y)
                                guard !overflow else { throw RuntimeError("arithmetic overflow") }
                                regs[Int(dst)] = .int(product)
                                continue
                            case .less: regs[Int(dst)] = .bool(x < y); continue
                            case .lessEqual: regs[Int(dst)] = .bool(x <= y); continue
                            case .greater: regs[Int(dst)] = .bool(x > y); continue
                            case .greaterEqual: regs[Int(dst)] = .bool(x >= y); continue
                            case .equal: regs[Int(dst)] = .bool(x == y); continue
                            case .notEqual: regs[Int(dst)] = .bool(x != y); continue
                            default: break
                            }
                        }
                        let value = try apply(op, regs[Int(lhs)], regs[Int(rhs)])
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
                        let site = code.callSites[Int(siteIndex)]
                        let argumentBase = base + Int(arguments)
                        if let (callee, calleeCode) = vmTarget(of: site) {
                            let maxCallDepth = task.run.limits.maxCallDepth
                            guard task.callDepth < maxCallDepth else {
                                throw RuntimeError("maximum call depth (\(maxCallDepth)) exceeded")
                            }
                            try checkInterrupt()
                            for index in 0..<calleeCode.parameterCount
                            where !calleeCode.parameterKinds[index]
                                .accepts(
                                    stack.base[argumentBase + index]
                                )
                            {
                                stack.base[argumentBase + index] = try checked(
                                    stack.base[argumentBase + index],
                                    for: callee.parameters[index],
                                    of: callee.name ?? "closure"
                                )
                            }
                            stack.callers.append(
                                VMCaller(
                                    code: code,
                                    function: function,
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
                            instructions = calleeCode.instructions
                            base = argumentBase
                            pc = 0
                            statement = -1
                            regs = stack.base + base
                        } else {
                            var given: [Argument] = []
                            for index in 0..<site.labels.count {
                                given.append(
                                    Argument(
                                        label: site.labels[index],
                                        value: .literal(stack.base[argumentBase + index])
                                    )
                                )
                                stack.base[argumentBase + index] = .nothing
                            }
                            let value = try evaluateCall(site.callee, given)
                            regs = stack.base + base
                            regs[Int(dst)] = value
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
                            let maxCallDepth = task.run.limits.maxCallDepth
                            guard task.callDepth < maxCallDepth else {
                                throw RuntimeError("maximum call depth (\(maxCallDepth)) exceeded")
                            }
                            try checkInterrupt()
                            for index in 0..<calleeCode.parameterCount
                            where !calleeCode.parameterKinds[index]
                                .accepts(
                                    stack.base[argumentBase + index]
                                )
                            {
                                stack.base[argumentBase + index] = try checked(
                                    stack.base[argumentBase + index],
                                    for: callee.parameters[index],
                                    of: callee.name ?? "closure"
                                )
                            }
                            stack.callers.append(
                                VMCaller(
                                    code: code,
                                    function: function,
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
                            instructions = calleeCode.instructions
                            base = argumentBase
                            pc = 0
                            statement = -1
                            regs = stack.base + base
                        } else {
                            let callee = regs[Int(calleeRegister)]
                            var given: [Argument] = []
                            for index in 0..<site.labels.count {
                                given.append(
                                    Argument(
                                        label: site.labels[index],
                                        value: .literal(stack.base[argumentBase + index])
                                    )
                                )
                                stack.base[argumentBase + index] = .nothing
                            }
                            let value = try evaluateCall(.literal(callee), given)
                            regs = stack.base + base
                            regs[Int(dst)] = value
                        }
                    case .box(let register):
                        regs[Int(register)] = .object(CellBox(regs[Int(register)]))
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
                    case .returnValue(let register):
                        var cursor = VMCursor(
                            function: function,
                            code: code,
                            base: base,
                            pc: pc,
                            statement: statement
                        )
                        if let value = try leave(
                            with: regs[Int(register)],
                            &cursor,
                            entryDepth: entryDepth,
                            on: stack
                        ) {
                            return value
                        }
                        (function, code, base, pc, statement) =
                            (cursor.function, cursor.code, cursor.base, cursor.pc, cursor.statement)
                        instructions = code.instructions
                        regs = stack.base + base
                    case .returnNothing:
                        var cursor = VMCursor(
                            function: function,
                            code: code,
                            base: base,
                            pc: pc,
                            statement: statement
                        )
                        if let value = try leave(
                            with: .nothing,
                            &cursor,
                            entryDepth: entryDepth,
                            on: stack
                        ) {
                            return value
                        }
                        (function, code, base, pc, statement) =
                            (cursor.function, cursor.code, cursor.base, cursor.pc, cursor.statement)
                        instructions = code.instructions
                        regs = stack.base + base
                    }
                }
            } catch {
                // The frames the error leaves, innermost first, each reporting it as the tree
                // evaluator does: the statement it was in, and the call it ended. A frame that has
                // code for it (a `catch`, a `defer`, a `try?`) goes on there instead.
                var error = error
                unwinding: while true {
                    // An error caught inside an expression has not left the statement.
                    let guarded = handler(in: code, at: pc - 1, for: error)
                    if !code.isImplicitReturn, guarded?.isExpression != true,
                        var runtime = error as? RuntimeError
                    {
                        if statement >= 0, let range = code.ranges[Int(statement)] {
                            if runtime.range == nil {
                                runtime.range = range
                            } else if let last = runtime.calls.indices.last,
                                runtime.calls[last].site == nil
                            {
                                runtime.calls[last].site = range
                            }
                        }
                        error = runtime
                    }
                    if let handler = guarded {
                        if handler.keepsError { stack.caught.append(error) }
                        if let register = handler.register, let runtime = error as? RuntimeError {
                            stack.base[base + Int(register)] = runtime.value
                        }
                        pc = handler.target
                        regs = stack.base + base
                        break unwinding
                    }
                    if !code.isImplicitReturn, !code.isProgram, var runtime = error as? RuntimeError
                    {
                        runtime.calls.append(
                            RuntimeError.Call(function: function.name ?? "a closure", site: nil)
                        )
                        error = runtime
                    }
                    let leaving = function
                    leaveFrame(function, code, base: base, stack)
                    guard stack.callers.count > entryDepth else { throw error }
                    let caller = stack.callers.removeLast()
                    function = caller.function
                    code = caller.code
                    instructions = code.instructions
                    base = caller.base
                    pc = caller.pc
                    statement = caller.statement
                    if let own = caller.scopes {
                        task.scopes = own
                    } else {
                        setScopes(of: function, from: leaving, task)
                    }
                    stack.top = base + code.frameSize
                }
            }
        }
    }

    /// The code that deals with an error raised at instruction `pc` of `code`: the innermost handler
    /// whose stretch has it and that catches this kind of error.
    private func handler(in code: Code, at pc: Int, for error: Error) -> Handler? {
        for handler in code.handlers.reversed() where handler.start <= pc && pc < handler.end {
            switch handler.catches {
            case .everything: return handler
            case .runtimeErrors: if error is RuntimeError { return handler }
            }
        }
        return nil
    }

    // swiftlint:enable cyclomatic_complexity function_body_length
}
