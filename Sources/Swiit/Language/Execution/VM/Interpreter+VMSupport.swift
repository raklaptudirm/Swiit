import Foundation

// What the loop of `Interpreter+VM.swift` uses: leaving a frame, finding handlers, making closures and
// finding what a call can enter.

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
        if let own = caller.scopes {
            task.scopes = own
        } else {
            setScopes(of: caller.function, from: callee, task)
        }
        stack.top = caller.base + caller.code.frameSize
        let conforming = try conformed(result, to: callee)
        stack.base[caller.destination] = conforming
        return nil
    }

    /// The cell a captured local is kept in.
    func cell(_ value: Value) throws -> Binding.Cell {
        guard case .object(let object) = value.storage, let box = object as? CellBox else {
            throw RuntimeError("a captured variable lost its cell")
        }
        return box.cell
    }

    /// A closure, as the tree evaluator makes one: it keeps the global scopes, the cells of the
    /// locals it names, and the values its capture list takes, each weakly if it says so.
    func makeClosure(
        _ site: ClosureSite,
        _ registers: UnsafeMutablePointer<Value>
    ) throws
        -> Value
    {
        let capture = Scope()
        for local in site.cells {
            capture.bindings[local.name] = Binding(
                cell: try cell(registers[Int(local.register)]),
                mutable: local.mutable
            )
        }
        for name in site.others {
            if let binding = localBinding(name) { capture.bindings[name] = binding }
        }
        let scopes = task.scopes
        var captured =
            scopes.count == 2 && capture.bindings.isEmpty
            ? scopes : Array(scopes.prefix(2)) + [capture]
        if !site.captures.isEmpty {
            let taken = Scope()
            for item in site.captures {
                var value = registers[Int(item.register)]
                if item.isWeak || item.isUnowned,
                    case .object(let instance as ClassInstance) = value.storage
                {
                    value = .object(WeakReference(instance))
                }
                taken.bindings[item.name] = Binding(value: value, mutable: false)
            }
            captured.append(taken)
        }
        return .function(
            Function(
                name: nil,
                parameters: site.literal.parameters,
                returnType: site.literal.returnType,
                body: .swiit(site.literal.body),
                captured: captured
            )
        )
    }

    /// The function a value is, when the VM can call it without leaving its loop: a compiled
    /// function that takes this many arguments, called through a value, so labels are not asked.
    func vmTarget(ofValue value: Value, arguments: Int) -> (Function, Code)? {
        guard case .function(let callable) = value.storage else { return nil }
        let only: Function
        if let function = callable as? Function {
            only = function
        } else if let set = callable as? OverloadSet, set.candidates.count == 1 {
            only = set.candidates[0]
        } else {
            return nil
        }
        guard only.parameters.count == arguments, let code = compiled(only), code.isPlain else {
            return nil
        }
        return (only, code)
    }

    /// The function a call site calls, when the VM can call it without leaving its loop: the one
    /// function the name is bound to, compiled, taking these arguments as written.
    func vmTarget(of site: CallSite) -> (Function, Code)? {
        guard let name = site.name, let binding = lookup(name),
            case .function(let callable) = binding.value.storage
        else { return nil }
        let only: Function
        if let function = callable as? Function {
            only = function
        } else if let set = callable as? OverloadSet, set.candidates.count == 1 {
            only = set.candidates[0]
        } else {
            return nil
        }
        guard let code = compiled(only), code.isPlain else { return nil }
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
