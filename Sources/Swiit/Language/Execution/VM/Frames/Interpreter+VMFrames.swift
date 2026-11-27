import Foundation

// Entering and leaving the frames of compiled code: a run from the tree evaluator or from outside, a
// loop of the program's run as compiled code, and what a frame undoes as it ends.

extension Interpreter {
    /// Runs a function the VM has code for, called from the tree evaluator or from outside: the
    /// arguments are in `arguments`, and what it gives is the result, conformed to its return type.
    func runCompiled(
        _ function: Function,
        _ code: Code,
        with arguments: BindingTable,
        receiver: Receiver? = nil,
        argumentsAt registers: Int? = nil
    ) throws -> Value {
        let task = self.task
        let stack = task.vm
        vmEntries += 1
        let base = stack.top
        stack.ensure(base + code.frameSize)
        // By position, so that no parameter is copied to be looked at.
        for index in 0..<function.parameters.count {
            if let registers {
                stack.base[base + index] = stack.base[registers + index]
            } else {
                stack.base[base + index] =
                    arguments[function.parameters[index].name]?.value ?? .nothing
            }
        }
        stack.top = base + code.frameSize
        let saved = (frame: task.frame, frameBase: task.frameBase)
        // Called where its scopes already are (a closure a native body runs), they are left as they are.
        let ownsScopes = receiver != nil || !code.isPlain
        var savedScopes: [Scope]?
        if ownsScopes || !task.scopes(are: function.captured) {
            savedScopes = task.scopes
            task.scopes = function.captured
        }
        // A method has `self`, and a generic function its type parameters, in a scope of the call.
        var own: Scope?
        if ownsScopes {
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
        // The class is pushed for `super`, which only a body that names it asks for.
        let owner = superclassOwner(of: function, code)
        if let owner { task.owners.append(owner) }
        if !code.isProgram { task.callDepth += 1 }
        task.frame = nil
        if let register = code.selfRegister, let binding = lookup("self") {
            stack.base[base + Int(register)] =
                code.selfStorage.holdsCell ? .object(binding.cell) : binding.value
        }
        defer {
            if let receiver, let changed = own?.bindings["self"]?.value { receiver.value = changed }
            if let savedScopes { task.scopes = savedScopes }
            task.frame = saved.frame
            task.frameBase = saved.frameBase
            if owner != nil { task.owners.removeLast() }
            stack.top = base
        }
        let result = try execute(function, code, base: base, on: stack)
        return code.returnKind.accepts(result) ? result : try conformed(result, to: function)
    }
}

extension Interpreter {
    /// A loop of a program's own code, run compiled: what it does to the globals it names, it does by
    /// name, and its own locals are registers. False if it is not one the VM takes, or the program's
    /// blocks have no frame, and the tree evaluator runs it.
    ///
    /// The one statement is compiled as a body with no parameters, its range the statement's own, so
    /// that an error and a step count are the tree evaluator's. It runs over the scopes the program is
    /// in, as a closure called where it is made would.
    func runCompiledLoop(of program: Program, at index: Int) throws -> Bool {
        guard engine == .vm, let frameSize = program.frameSize else { return false }
        switch program.statements[index] {
        case .forLoop, .whileLoop: break
        default: return false
        }
        var body = Program(
            statements: [program.statements[index]],
            ranges: index < program.ranges.count ? [program.ranges[index]] : []
        )
        body.frameSize = frameSize
        body.capturedSlots = program.capturedSlots
        let function = Function(
            name: nil,
            parameters: [],
            returnType: nil,
            body: .swiit(body),
            captured: task.scopes
        )
        guard let code = compiled(function) else { return false }
        code.isProgram = true
        vmLoops += 1
        _ = try runCompiled(function, code, with: [:])
        return true
    }
}

extension Interpreter {
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
}

extension Interpreter {
    /// A frame returns `result`. The entry frame's is the run's; another's goes to the register its
    /// caller named, and the caller goes on. The result is conformed to the callee's return type once
    /// the callee is gone, which is where the tree evaluator does it.
    func leave(
        with result: Value,
        _ cursor: inout VMCursor,
        entryDepth: Int,
        on stack: VMStack
    ) throws -> Value? {
        let callee = cursor.function
        let calleeCode = cursor.code
        leaveFrame(callee, calleeCode, base: cursor.base, stack)
        if stack.callers.count == entryDepth { return result }
        let caller = stack.callers.removeLast()
        defer { caller.releaseCallee() }
        cursor = VMCursor(
            function: caller.function,
            code: caller.code,
            base: caller.base,
            pc: caller.pc,
            statement: caller.statement
        )
        if caller.hasScopes {
            task.scopes = stack.savedScopes.removeLast()
        } else if !caller.sameScopes {
            setScopes(of: caller.function, from: callee, task)
        }
        stack.top = caller.base + caller.code.frameSize
        var made: Value?
        if caller.isMethod { made = try finishMethod(stack.methodExits.removeLast(), on: stack) }
        let conforming =
            try made
            ?? (calleeCode.returnKind.accepts(result) ? result : conformed(result, to: callee))
        stack.base[caller.destination] = conforming
        return nil
    }
}

extension Interpreter {
    /// What a frame does as it ends, however it ends: its registers are let go, its call is over, and
    /// the tasks it started are closed.
    func leaveFrame(_ function: Function, _ code: Code, base: Int, _ stack: VMStack) {
        VMStack.clear(stack.base + base, count: code.frameSize)
        let task = self.task
        if !code.isProgram { task.callDepth -= 1 }
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
}
