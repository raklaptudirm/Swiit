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
        let calleeCode = cursor.code
        leaveFrame(callee, calleeCode, base: cursor.base, stack)
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
        } else if !caller.sameScopes {
            setScopes(of: caller.function, from: callee, task)
        }
        stack.top = caller.base + caller.code.frameSize
        let conforming =
            calleeCode.returnKind.accepts(result) ? result : try conformed(result, to: callee)
        stack.base[caller.destination] = conforming
        return nil
    }

    /// `checkInterrupt` for the loop, which has the task and its run in hand.
    @inline(__always)
    func tick(_ task: TaskContext, _ run: RunState) throws {
        if hasPendingDeinits { runPendingDeinits() }
        run.steps += 1
        if task.cancellation.isSet { throw Cancelled() }
        run.stepsUntilCheck -= 1
        if run.stepsUntilCheck <= 0 { try checkLimits() }
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
        guard only.parameters.count == arguments, let code = compiled(only), code.isPlain,
            code.selfRegister == nil
        else {
            return nil
        }
        return (only, code)
    }

    /// The function a call site calls, when the VM can call it without leaving its loop: the one
    /// function the name is bound to, compiled, taking these arguments as written.
    func vmTarget(of site: CallSite, from caller: Function) -> VMTarget? {
        // A name found to be a struct's is not looked up again for a function.
        if site.constructedType != nil || site.constructedClass != nil,
            site.constructedVersion == scopeVersion,
            site.constructedCaller == ObjectIdentifier(caller)
        {
            return nil
        }
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
        guard let code = compiled(only), code.isPlain, code.selfRegister == nil else { return nil }
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
        guard fits else { return nil }
        let shares =
            only.captured.count == caller.captured.count
            && zip(only.captured, caller.captured).allSatisfy { $0 === $1 }
        // A variable that holds a function can be assigned another without the names changing.
        if binding.isFunction {
            site.cached = CallSite.Cached(caller: caller, callee: only, code: code)
            site.cachedCaller = ObjectIdentifier(caller)
            site.cachedVersion = scopeVersion
            site.cachedCallee = Unmanaged.passUnretained(only)
            site.cachedCode = Unmanaged.passUnretained(code)
            site.cachedSharesScopes = shares
        }
        return VMTarget(function: only, code: code, sharesScopes: shares)
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
        let base = stack.top
        stack.ensure(base + code.frameSize)
        for (index, parameter) in function.parameters.enumerated() {
            stack.base[base + index] =
                registers.map { stack.base[$0 + index] }
                ?? arguments[parameter.name]?.value ?? .nothing
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
        if let register = code.selfRegister, let binding = lookup("self") {
            stack.base[base + Int(register)] = .object(CellBox(cell: binding.cell))
        }
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

extension Interpreter {
    /// Finds the cell of the variable `site` names, from the scopes `function` runs in, and keeps it
    /// until a name changes. Nothing is kept for a variable that is worked out when read, or for a
    /// body that has a scope of its own.
    func findGlobal(_ site: GlobalSite, _ function: Function, _ code: Code) {
        site.version = scopeVersion
        site.function = ObjectIdentifier(function)
        site.cell = nil
        guard code.isPlain, let binding = lookup(site.name), !binding.isComputed else { return }
        site.cell = binding.cell
        site.isMutable = binding.mutable && binding.special == nil
    }

    /// `cell = value` or `cell op= value` when both are plainly numbers of one kind: false when the
    /// assignment is for the general one to make (another kind, an operator a type defines, a check
    /// of the value against the variable's type).
    @inline(__always)
    func setNumber(in cell: Binding.Cell, _ op: BinaryOperator?, to value: Value) -> Bool {
        switch (cell.value.storage, value.storage) {
        case (.int(let current), .int(let new)):
            switch op {
            case nil: cell.value = .int(new)
            case .add?:
                let (sum, overflow) = current.addingReportingOverflow(new)
                guard !overflow else { return false }
                cell.value = .int(sum)
            case .subtract?:
                let (difference, overflow) = current.subtractingReportingOverflow(new)
                guard !overflow else { return false }
                cell.value = .int(difference)
            case .multiply?:
                let (product, overflow) = current.multipliedReportingOverflow(by: new)
                guard !overflow else { return false }
                cell.value = .int(product)
            default: return false
            }
            return true
        case (.double(let current), .double(let new)):
            switch op {
            case nil: cell.value = .double(new)
            case .add?: cell.value = .double(current + new)
            case .subtract?: cell.value = .double(current - new)
            case .multiply?: cell.value = .double(current * new)
            default: return false
            }
            return true
        default: return false
        }
    }
}

extension Value {
    /// Whether this is a list whose first element is of the kind `element` is.
    func isList(likeElement element: Value) -> Bool {
        guard case .list(let items) = storage, let first = items.first else { return false }
        switch (first.storage, element.storage) {
        case (.int, .int), (.double, .double), (.bool, .bool), (.string, .string): return true
        default: return false
        }
    }

    /// Appends `element` to this list when its first element is of the kind `element` is (a number,
    /// a Bool or a string, each its own), so that no conversion to the list's element type is in
    /// question. The list is changed where it is, not copied. False, and nothing changed, otherwise.
    mutating func appendLikeElements(_ element: Value) -> Bool {
        guard case .list(var items) = storage, let first = items.first else { return false }
        switch (first.storage, element.storage) {
        case (.int, .int), (.double, .double), (.bool, .bool), (.string, .string): break
        default: return false
        }
        storage = .nothing
        items.append(element)
        storage = .list(items)
        return true
    }
}

extension Interpreter {
    /// An operation on two integers that needs no general `apply`: nil for one that does (a division,
    /// a shift), which gives what `apply` gives; an overflow is an error, as there.
    @inline(__always)
    static func arithmetic(_ op: BinaryOperator, _ x: Int, _ y: Int) throws -> Value? {
        switch op {
        case .add:
            let (sum, overflow) = x.addingReportingOverflow(y)
            guard !overflow else { throw RuntimeError("arithmetic overflow") }
            return .int(sum)
        case .subtract:
            let (difference, overflow) = x.subtractingReportingOverflow(y)
            guard !overflow else { throw RuntimeError("arithmetic overflow") }
            return .int(difference)
        case .multiply:
            let (product, overflow) = x.multipliedReportingOverflow(by: y)
            guard !overflow else { throw RuntimeError("arithmetic overflow") }
            return .int(product)
        case .less: return .bool(x < y)
        case .lessEqual: return .bool(x <= y)
        case .greater: return .bool(x > y)
        case .greaterEqual: return .bool(x >= y)
        case .equal: return .bool(x == y)
        case .notEqual: return .bool(x != y)
        default: return nil
        }
    }

    /// What a member of a list or a string the loop makes itself gives, when the receiver and argument
    /// are plainly of the kinds it knows; nil, with nothing changed, otherwise. Each but a subscript
    /// makes the one step the tree evaluator's call of the member does.
    func fastMember(
        _ kind: FastMember,
        _ registers: UnsafeMutablePointer<Value>,
        _ receiver: Register,
        _ argument: Register
    ) throws -> Value? {
        switch kind {
        case .append:
            guard registers[Int(receiver)].isList(likeElement: registers[Int(argument)]) else {
                return nil
            }
            try checkInterrupt()
            _ = registers[Int(receiver)].appendLikeElements(registers[Int(argument)])
            return .nothing
        case .listCount:
            guard case .list(let items) = registers[Int(receiver)].storage else { return nil }
            try checkInterrupt()
            return .int(items.count)
        case .element:
            guard case .list(let items) = registers[Int(receiver)].storage,
                case .int(let index) = registers[Int(argument)].storage,
                index >= 0, index < items.count
            else { return nil }
            return items[index]
        case .stringCount:
            guard case .string(let text) = registers[Int(receiver)].storage else { return nil }
            try checkInterrupt()
            return .int(text.count)
        }
    }
}

extension Interpreter {
    /// The value of the global `site` names, read from its cell when it has one, and by the tree
    /// evaluator's lookup where it has not (a variable that is not there, or is worked out, or weak).
    @inline(__always)
    func globalValue(_ site: GlobalSite, _ function: Function, _ code: Code) throws -> Value {
        if !(site.version == scopeVersion && site.function == ObjectIdentifier(function)) {
            findGlobal(site, function, code)
        }
        if let cell = site.cell {
            let value = cell.value
            if case .object(is WeakReference) = value.storage {
                return try evaluate(.variable(site.name))
            }
            return value
        }
        return try evaluate(.variable(site.name))
    }

    /// `name = value` or `name op= value` of a global: set in its cell when both are numbers of one
    /// kind, and by the tree evaluator's assignment where not.
    @inline(__always)
    func assignGlobal(
        _ site: GlobalSite,
        _ assignment: Assignment,
        _ value: Value,
        _ function: Function,
        _ code: Code
    ) throws {
        if !(site.version == scopeVersion && site.function == ObjectIdentifier(function)) {
            findGlobal(site, function, code)
        }
        if site.isMutable, let cell = site.cell, setNumber(in: cell, assignment.op, to: value) {
            return
        }
        var long = assignment
        long.value = .literal(value)
        try assign(long)
    }
}

extension Interpreter {
    /// `value.name`: a stored field of a struct is read where it is, and any other member by the
    /// routine the tree evaluator reads them with.
    @inline(__always)
    func loadMember(_ name: String, _ value: Value) throws -> Value {
        switch value.storage {
        case .structure(let structure):
            if let field = structure.record[name] { return field }
        case .object(let object):
            // A stored field of a class's instance, as `classMember` reads it first.
            if let instance = object as? ClassInstance, let stored = instance.storage[name] {
                return read(stored)
            }
        default: break
        }
        return try member(name, of: value)
    }
}

extension Interpreter {
    /// A call the loop does not make itself: the tree evaluator's, with the arguments in the registers
    /// from `arguments` on, which it takes.
    func evaluateCall(_ site: CallSite, _ callee: Expr, _ arguments: Int) throws -> Value {
        let stack = task.vm
        var given: [Argument] = []
        for index in 0..<site.labels.count {
            given.append(
                Argument(
                    label: site.labels[index],
                    value: .literal(stack.base[arguments + index])
                )
            )
            stack.base[arguments + index] = .nothing
        }
        return try evaluateCall(callee, given)
    }
}
