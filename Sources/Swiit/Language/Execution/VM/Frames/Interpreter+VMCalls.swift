import Foundation

// Finding what a call enters and putting its arguments where the callee's parameters are.

extension Interpreter {
    /// The function a value is, when the VM can call it without leaving its loop: a compiled
    /// function that takes this many arguments, called through a value, so labels are not asked.
    @inline(never)
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
    @inline(never)
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
        } else if let set = callable as? OverloadSet, let chosen = site.overload,
            set.candidates.indices.contains(chosen)
        {
            // The one the checker chose, as `narrowed` takes it.
            only = set.candidates[chosen]
        } else {
            return nil
        }
        guard let code = compiled(only), code.isPlain, code.selfRegister == nil else { return nil }
        if site.lastFunction !== only {
            site.lastFunction = only
            site.lastMapping = argumentMapping(of: only, labels: site.labels)
            site.lastDefaults = site.lastMapping?.contains(-1) ?? false
            site.lastFits = site.lastMapping != nil
        }
        // A value of function type is called with its arguments in order, whatever they are labeled.
        let fits =
            binding.isFunction
            ? site.lastFits : only.parameters.count == site.labels.count
        // A variable that holds a function does not have the defaults its parameters had.
        guard fits, binding.isFunction || !site.lastDefaults else { return nil }
        let shares =
            only.captured.count == caller.captured.count
            && zip(only.captured, caller.captured).allSatisfy { $0 === $1 }
        // A variable that holds a function can be assigned another without the names changing.
        if binding.isFunction, !site.lastDefaults {
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
    /// A call the loop does not make itself: the tree evaluator's, with the arguments in the registers
    /// from `arguments` on, which it takes.
    func evaluateCall(_ site: CallSite, _ callee: Expr, _ arguments: Int) throws -> Value {
        noteSlowCall(site)
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

extension Interpreter {
    /// Counts a call the loop hands to the tree evaluator by what it calls.
    func noteSlowCall(_ site: CallSite) {
        var kind = "a call on a value"
        if let name = site.name {
            switch lookup(name)?.value.storage {
            case .function(let callable)?:
                if let set = callable as? OverloadSet {
                    if set.candidates.count != 1 {
                        kind = "overloaded function"
                    } else if argumentMapping(of: set.candidates[0], labels: site.labels) == nil {
                        kind = "function, arguments that do not fit (variadic, trailing closure)"
                    } else if set.candidates[0].effect == .async {
                        kind = "async function"
                    } else if case .native = set.candidates[0].body {
                        kind = "native function"
                    } else if compiled(set.candidates[0]) == nil {
                        kind = "function the VM does not compile"
                    } else {
                        kind = "function, not plain (generic, variadic, labels)"
                    }
                } else if let function = callable as? Function {
                    if case .native = function.body {
                        kind = "native closure"
                    } else {
                        kind = "closure value"
                    }
                } else {
                    kind = "other callable"
                }
            case .object(let object)?:
                kind =
                    object is StructType
                    ? "struct type" : object is ClassType ? "class type" : "other type"
            default: kind = "unknown name"
            }
        }
        vmSlowCalls[kind, default: 0] += 1
    }
}

extension Interpreter {
    /// How a call with these labels is bound to the parameters of `function` as `bind` does it, for a
    /// function whose parameters are plain: each parameter takes the next argument if the label is its,
    /// and otherwise its default. Nil where it does not fit, or a parameter is variadic or filled by
    /// the host.
    func argumentMapping(of function: Function, labels: [String?]) -> [Int]? {
        var mapping: [Int] = []
        var index = 0
        for parameter in function.parameters {
            if parameter.variadic || parameter.externalDefault != nil { return nil }
            if index < labels.count, labels[index] == parameter.label {
                mapping.append(index)
                index += 1
            } else if parameter.defaultValue != nil {
                mapping.append(-1)
            } else {
                return nil
            }
        }
        return index == labels.count ? mapping : nil
    }

    /// Puts the arguments of a call in the places of the parameters they are for, from the registers
    /// at `base`, and the defaults of the parameters left out, as `bind` evaluates them.
    @inline(never)
    func placeArguments(_ mapping: [Int], of function: Function, at base: Int) throws {
        let stack = task.vm
        let needed = base + mapping.count
        stack.ensure(needed)
        for position in stride(from: mapping.count - 1, through: 0, by: -1)
        where mapping[position] >= 0 && mapping[position] != position {
            stack.base[base + position] = stack.base[base + mapping[position]]
        }
        // What the defaults run may use the stack above the caller's registers.
        let savedTop = stack.top
        stack.top = max(stack.top, needed)
        defer { stack.top = savedTop }
        for (position, parameter) in function.parameters.enumerated() where mapping[position] < 0 {
            guard let expression = parameter.defaultValue else { continue }
            let value: Value
            if case .literal(let literal) = expression,
                ParameterKind(parameter.type).accepts(literal)
            {
                value = literal
            } else {
                value = try defaultArgument(expression, for: parameter, of: function)
            }
            stack.base[base + position] = value
        }
    }
}

extension Interpreter {
    /// Makes each argument of a call the type its parameter has, where it is not plainly of it already.
    @inline(__always)
    func checkArguments(
        of callee: Function,
        _ code: Code,
        at argumentBase: Int,
        on stack: VMStack
    ) throws {
        for index in 0..<code.parameterCount
        where !code.kindTable[index].accepts(at: stack.base + argumentBase + index) {
            stack.base[argumentBase + index] = try checked(
                stack.base[argumentBase + index],
                for: callee.parameters[index],
                of: callee.name ?? "closure"
            )
        }
    }
}

extension Interpreter {
    /// A call that leaves out parameters with defaults: the arguments go where the parameters are, the
    /// defaults are made, and each is made the type its parameter has, as `bind` does.
    func placeAndCheckArguments(
        _ mapping: [Int],
        of function: Function,
        at base: Int
    ) throws {
        try placeArguments(mapping, of: function, at: base)
        let stack = task.vm
        for (index, parameter) in function.parameters.enumerated()
        where !ParameterKind(parameter.type).accepts(at: stack.base + base + index) {
            stack.base[base + index] = try checked(
                stack.base[base + index],
                for: parameter,
                of: function.name ?? "closure"
            )
        }
    }
}
