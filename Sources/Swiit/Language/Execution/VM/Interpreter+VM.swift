import Foundation

/// How a function body runs: on the tree evaluator, or compiled to `Code` and run by the VM where the
/// compiler handles it (`Docs/vm.md`). Both run the same checked program and give the same results.
enum Engine: Sendable {
    case tree
    case vm

    /// The engine a new interpreter starts with. Building with `-Xswiftc -DSWIIT_VM_ENGINE` makes it
    /// the VM, which runs the test suites against it.
    static var initial: Engine {
        #if SWIIT_VM_ENGINE
        .vm
        #else
        .tree
        #endif
    }
}

/// What the VM made of a function body, kept with the function.
enum VMCode {
    case untried
    case code(Code)
    case unsupported
}

extension Function {
    /// Whether the compiler may take this body: a plain function or closure of the global scopes,
    /// whose parameters are taken as they come.
    var isCompilable: Bool {
        guard case .swiit(let program) = body, program.frameSize != nil, captured.count <= 2,
            owner == nil, !isMutating, !isFailable, !isConvenience, typeParameters.isEmpty,
            inoutNames.isEmpty, effect == .sync
        else { return false }
        return parameters.allSatisfy {
            !$0.variadic && !$0.isInout && !$0.isAutoclosure && $0.resultBuilder == nil
        }
    }
}

/// Where a frame is: the function, its code, its registers, and the next instruction.
struct VMCursor {
    var function: Function
    var code: Code
    var base: Int
    var pc: Int
    var statement: Int32
}

/// A caller's place while the function it called runs.
struct VMCaller {
    var code: Code
    var function: Function
    var pc: Int
    var base: Int
    var statement: Int32
    /// The register, counted from the stack's start, the callee's result goes to.
    var destination: Int
}

/// The registers of a task's compiled code, one frame after another, and where each caller was. A
/// frame's registers are a window of it, so a call makes nothing: the arguments are written where the
/// callee's parameters are.
final class VMStack {
    private(set) var base: UnsafeMutablePointer<Value>
    private(set) var capacity: Int
    /// The first register no frame uses.
    @exclusivity(unchecked) var top = 0
    @exclusivity(unchecked) var callers: [VMCaller] = []

    init() {
        capacity = 1 << 12
        base = .allocate(capacity: capacity)
        base.initialize(repeating: .nothing, count: capacity)
    }

    deinit {
        base.deinitialize(count: capacity)
        base.deallocate()
    }

    /// Room for `needed` registers. A stack that grows moves, so a pointer into it is taken again
    /// afterward.
    func ensure(_ needed: Int) {
        guard needed > capacity else { return }
        var larger = capacity
        while larger < needed { larger *= 2 }
        let moved = UnsafeMutablePointer<Value>.allocate(capacity: larger)
        moved.moveInitialize(from: base, count: capacity)
        (moved + capacity).initialize(repeating: .nothing, count: larger - capacity)
        base.deallocate()
        base = moved
        capacity = larger
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
            guard let code = CodeCompiler.compile(function) else {
                function.vmCode = .unsupported
                return nil
            }
            function.vmCode = .code(code)
            return code
        }
    }

    /// Runs a function the VM has code for, called from the tree evaluator or from outside: the
    /// arguments are in `arguments`, and what it gives is the result, conformed to its return type.
    func runCompiled(
        _ function: Function,
        _ code: Code,
        with arguments: BindingTable
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
        task.frame = nil
        task.callDepth += 1
        defer {
            task.scopes = saved.scopes
            task.frame = saved.frame
            task.frameBase = saved.frameBase
            stack.top = base
        }
        let result = try execute(function, code, base: base, on: stack)
        return try conformed(result, to: function)
    }

    /// `result` as the function's return type says, or the error the tree evaluator gives.
    private func conformed(_ result: Value, to function: Function) throws -> Value {
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
    private func leaveFrame(_ function: Function, _ code: Code, base: Int, _ stack: VMStack) {
        for index in 0..<code.frameSize { stack.base[base + index] = .nothing }
        let task = self.task
        task.callDepth -= 1
        if task.lastCallee !== function { task.lastCallee = function }
        if !task.children.isEmpty, let last = task.children.last, last.depth > task.callDepth {
            closeTasks(above: task.callDepth)
        }
    }

    /// Makes the scopes of `callee` the task's, which are those of `caller` already when both are
    /// functions of the global scopes: the task's scopes are always its running function's.
    private func setScopes(of callee: Function, from caller: Function, _ task: TaskContext) {
        let wanted = callee.captured
        let current = caller.captured
        if wanted.count == current.count, wanted.count <= 2,
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
    private func execute(
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
                                    destination: base + Int(dst)
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
                // evaluator does: the statement it was in, and the call it ended.
                var error = error
                while true {  // Each frame it leaves, until the entry frame's.
                    if !code.isImplicitReturn, var runtime = error as? RuntimeError {
                        if statement >= 0, let range = code.ranges[Int(statement)] {
                            if runtime.range == nil {
                                runtime.range = range
                            } else if let last = runtime.calls.indices.last,
                                runtime.calls[last].site == nil
                            {
                                runtime.calls[last].site = range
                            }
                        }
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
                    setScopes(of: function, from: leaving, task)
                    stack.top = base + code.frameSize
                }
            }
        }
    }

    // swiftlint:enable cyclomatic_complexity function_body_length

    /// A frame returns `result`. The entry frame's is the run's; another's goes to the register its
    /// caller named, and the caller goes on. The result is conformed to the callee's return type once
    /// the callee is gone, which is where the tree evaluator does it.
    private func leave(
        with result: Value,
        _ cursor: inout VMCursor,
        entryDepth: Int,
        on stack: VMStack
    ) throws -> Value? {
        let callee = cursor.function
        leaveFrame(callee, cursor.code, base: cursor.base, stack)
        if stack.callers.count == entryDepth { return result }
        let caller = stack.callers.removeLast()
        cursor = VMCursor(
            function: caller.function,
            code: caller.code,
            base: caller.base,
            pc: caller.pc,
            statement: caller.statement
        )
        setScopes(of: caller.function, from: callee, task)
        stack.top = caller.base + caller.code.frameSize
        let conforming = try conformed(result, to: callee)
        stack.base[caller.destination] = conforming
        return nil
    }

    /// The function a call site calls, when the VM can call it without leaving its loop: the one
    /// function the name is bound to, compiled, taking these arguments as written.
    private func vmTarget(of site: CallSite) -> (Function, Code)? {
        guard let binding = lookup(site.name), case .function(let callable) = binding.value.storage
        else { return nil }
        let only: Function
        if let function = callable as? Function {
            only = function
        } else if let set = callable as? OverloadSet, set.candidates.count == 1 {
            only = set.candidates[0]
        } else {
            return nil
        }
        guard let code = compiled(only) else { return nil }
        if site.lastFunction !== only {
            site.lastFunction = only
            site.lastFits =
                only.parameters.count == site.labels.count
                && zip(only.parameters, site.labels).allSatisfy { $0.label == $1 }
        }
        // A value of function type is called with its arguments in order, whatever they are labeled.
        let fits =
            binding.isFunction
            ? site.lastFits : only.parameters.count == site.labels.count
        return fits ? (only, code) : nil
    }
}
