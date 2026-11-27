import Foundation

// Calls of functions written in Swift by name (`max(a, b)`, `abs(x)`), as the loop makes them: the
// arguments go from the registers to the body by a plan the call site keeps, and not through the
// tree evaluator's call, which looks the name up and binds the arguments by name each time.

extension Interpreter {
    /// The call of a native function by a plan, as `invoke` makes it: nil, with nothing done, where
    /// the name is not one a plan calls (a Swiit function, a type, several overloads the checker did
    /// not choose between, a call whose labels do not fit).
    func callNativeFunction(
        _ call: ConstructCall,
        from caller: Function,
        on stack: VMStack
    ) throws -> Value? {
        let site = call.site
        if site.nativeVersion != scopeVersion || site.nativeCaller != ObjectIdentifier(caller) {
            site.nativeVersion = scopeVersion
            site.nativeCaller = ObjectIdentifier(caller)
            site.nativePlan = nativeFunctionPlan(for: site)
        }
        guard let plan = site.nativePlan else { return nil }

        let function = plan.function
        var arguments = Arguments(capacity: plan.fills.count)
        for (index, parameter) in function.parameters.enumerated() {
            var value: Value
            switch plan.fills[index] {
            case .argument(let position):
                let register = stack.base + call.argumentBase + position
                value = register.move()
                register.initialize(to: .nothing)
                if !plan.kinds[index].accepts(value), !plan.checks[index].accepts(value) {
                    value = try checked(value, for: parameter, of: function.name ?? "function")
                }
            case .value(let fixed):
                value = fixed
            case .rest(let first):
                var items: [Value] = []
                for position in first..<site.labels.count {
                    let register = stack.base + call.argumentBase + position
                    items.append(register.move())
                    register.initialize(to: .nothing)
                }
                // A list of what the element's kind plainly takes (none, often) is as it is.
                if items.allSatisfy({ plan.elementKinds[index].accepts($0) }) {
                    value = .list(items)
                } else {
                    value = try checked(
                        .list(items),
                        for: parameter,
                        of: function.name ?? "function"
                    )
                }
            }
            arguments[parameter.name] = value
        }

        defer { task.lastCallee = function }
        let maxCallDepth = task.run.maxCallDepth
        guard callDepth < maxCallDepth else {
            throw RuntimeError("maximum call depth (\(maxCallDepth)) exceeded")
        }
        try checkInterrupt()
        return try plan.body(self, arguments)
    }

    /// The plan for the function a site's name is, if it is a native function, the only one of its
    /// name or the overload the checker chose, whose parameters the call's labels fill.
    private func nativeFunctionPlan(for site: CallSite) -> NativeFunctionPlan? {
        guard let name = site.name, case .function(let callable)? = lookup(name)?.value.storage
        else { return nil }
        let function: Function
        if let single = callable as? Function {
            function = single
        } else if let set = callable as? OverloadSet {
            let chosen = set.candidates.count == 1 ? 0 : site.overload
            guard let chosen, set.candidates.indices.contains(chosen) else { return nil }
            function = set.candidates[chosen]
        } else {
            return nil
        }
        guard case .native(let body) = function.body, function.inoutNames.isEmpty,
            let fills = Interpreter.nativeFills(of: function.parameters, labels: site.labels)
        else { return nil }
        return NativeFunctionPlan(function: function, body: body, fills: fills)
    }

    /// What each parameter is given by a call with these labels, as `bind` matches them: in order, a
    /// parameter takes the next argument if the labels agree; a variadic one, last, takes the rest;
    /// one the call leaves out takes its default, given as a literal. Nil for a call that needs more.
    static func nativeFills(
        of parameters: [Parameter],
        labels: [String?]
    ) -> [NativeFunctionPlan.Fill]? {
        var fills: [NativeFunctionPlan.Fill] = []
        var next = 0
        for (index, parameter) in parameters.enumerated() {
            if parameter.variadic {
                // Only last, and only of arguments with the label of the first.
                guard index == parameters.count - 1,
                    labels[next...].enumerated()
                        .allSatisfy({
                            $0.offset == 0 ? $0.element == parameter.label : $0.element == nil
                        })
                else { return nil }
                fills.append(.rest(next))
                next = labels.count
            } else if next < labels.count, labels[next] == parameter.label {
                fills.append(.argument(next))
                next += 1
            } else if case .literal(let value)? = parameter.defaultValue {
                fills.append(.value(value))
            } else {
                return nil
            }
        }
        return next == labels.count ? fills : nil
    }
}
