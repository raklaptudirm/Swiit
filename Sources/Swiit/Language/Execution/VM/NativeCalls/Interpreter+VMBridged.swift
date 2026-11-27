import Foundation

// Calls of the members of Swift's types, as the loop makes them: from the values in the registers, by a
// plan where the member takes each parameter an argument.

extension Interpreter {
    /// Finds the member a site calls, and a plan to call it by when it takes each parameter an argument
    /// of the labels the site gives, none variadic or left to a default.
    private func plan(_ site: BridgedSite) {
        site.isPlanned = true
        guard let member = bridged[site.type]?.lowered[site.member] else { return }
        let function = Function(
            name: member.name,
            parameters: member.parameters,
            returnType: nil,
            body: member.body
        )
        site.found = (member, function)
        guard !member.isMutating, let positional = member.positional,
            member.parameters.count == site.labels.count,
            zip(member.parameters, site.labels)
                .allSatisfy({
                    $0.label == $1 && !$0.variadic && $0.externalDefault == nil
                })
        else { return }
        site.plan = BridgedPlan(positional: positional, function: function, typeName: site.type)
    }

    /// The call of a planned member: what `bind` and `invoke` do for the call, without the table of
    /// arguments by name.
    private func callPlanned(
        _ plan: BridgedPlan,
        receiver: Value?,
        arguments: Int,
        on stack: VMStack
    ) throws -> Value {
        var values = stack.argumentArrays.popLast() ?? []
        values.reserveCapacity(plan.kinds.count)
        for index in plan.kinds.indices {
            values.append(stack.base[arguments + index])
            stack.base[arguments + index] = .nothing
        }
        for index in plan.kinds.indices where !plan.kinds[index].accepts(values[index]) {
            if plan.kinds[index] == .typeParameter, !hasBoundTypeArguments { continue }
            values[index] = try checked(values[index], for: plan.parameters[index], of: plan.name)
        }
        // Through `?.`: nil stays nil.
        if let receiver, receiver == .nothing, !plan.keepsNilReceiver { return .nothing }
        defer { if task.lastCallee !== plan.function { task.lastCallee = plan.function } }
        let maxCallDepth = task.run.maxCallDepth
        guard callDepth < maxCallDepth else {
            throw RuntimeError("maximum call depth (\(maxCallDepth)) exceeded")
        }
        try checkInterrupt()
        // An error it throws is one a script can catch, as a function's is.
        let result: Value
        do { result = try plan.positional(receiver ?? .nothing, values) } catch {
            throw hostFailure(error, in: plan.place)
        }
        // A body that kept the array has made the storage its own: it is not reused.
        values.removeAll(keepingCapacity: true)
        stack.argumentArrays.append(values)
        return result
    }
}

extension Interpreter {
    /// A member of a Swift type run as the tree evaluator runs it, with the receiver and the arguments
    /// (in the registers from `arguments` on) taken as they are.
    func callBridged(
        _ site: BridgedSite,
        receiver: Value?,
        arguments: Int,
        on stack: VMStack
    ) throws -> Value {
        if !site.isPlanned { plan(site) }
        if let plan = site.plan {
            return try callPlanned(plan, receiver: receiver, arguments: arguments, on: stack)
        }
        var given: [Argument] = []
        given.reserveCapacity(site.labels.count)
        for index in 0..<site.labels.count {
            given.append(
                Argument(label: site.labels[index], value: .literal(stack.base[arguments + index]))
            )
            stack.base[arguments + index] = .nothing
        }
        if site.found == nil, let member = bridged[site.type]?.lowered[site.member] {
            site.found = (
                member,
                Function(
                    name: member.name,
                    parameters: member.parameters,
                    returnType: nil,
                    body: member.body
                )
            )
        }
        guard let (member, function) = site.found else {
            return try runBridged(
                site.type,
                site.member,
                receiver: receiver.map { .literal($0) },
                given
            )
        }
        return try runBridged(
            site.type,
            member,
            function,
            receiver: receiver.map { .literal($0) },
            given
        )
    }
}
