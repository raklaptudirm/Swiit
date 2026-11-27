import Foundation

// Calling a method from the loop: finding it for the receiver, and what its frame does with `self` as it
// begins and ends.

/// The registers a `callMethod` instruction names.
struct CallOperands {
    let dst: Register
    let receiver: Register
    let arguments: Register
    let offset: Int32
}

/// A method the loop is to call: what the site found, and whether its receiver is a class's instance.
struct MethodTarget {
    let function: Function
    let code: Code
    let isClass: Bool
    /// The arguments to place, when the call leaves out parameters that have defaults.
    let mapping: [Int]?
}

extension Interpreter {
    /// A struct's plain method called on `receiver` with the arguments in the registers from
    /// `arguments` on, when the site has found it to be one and the arguments are plainly of the types
    /// it takes; nil, with nothing done, otherwise. What the tree evaluator's call of it does, in the
    /// same steps, without finding the method again by name or binding its arguments in a table.
    func methodTarget(
        _ site: MethodSite,
        receiver: Value,
        arguments: Int,
        owner: ClassType?
    ) throws -> MethodTarget? {
        if site.isSuper {
            guard let parent = owner?.superclass, case .object = receiver.storage else {
                return nil
            }
            if site.version != scopeVersion || site.classType != ObjectIdentifier(parent) {
                site.version = scopeVersion
                site.type = nil
                site.classType = ObjectIdentifier(parent)
                (site.function, site.code) = plainMethod(site, of: parent)
            }
        } else {
            switch receiver.storage {
            case .structure(let structure):
                guard let typeRef = structure.typeRefIfAny else { return nil }
                if site.version != scopeVersion || site.type != typeRef {
                    site.version = scopeVersion
                    site.type = typeRef
                    site.classType = nil
                    (site.function, site.code) = plainMethod(site, of: structure.record)
                }
            case .object(let object):
                guard let instance = object as? ClassInstance else { return nil }
                if site.version != scopeVersion || site.classType != ObjectIdentifier(instance.type)
                {
                    site.version = scopeVersion
                    site.type = nil
                    site.classType = ObjectIdentifier(instance.type)
                    (site.function, site.code) = plainMethod(site, of: instance.type)
                }
            default:
                return nil
            }
        }
        guard let function = site.function, let code = site.code else { return nil }
        let stack = task.vm
        // With defaults the arguments are not in the places of the parameters yet: they are checked as
        // they are placed.
        if site.mapping == nil {
            for index in 0..<code.parameterCount
            where !code.parameterKinds[index].accepts(at: stack.base + arguments + index) {
                return nil
            }
        }
        let maxCallDepth = task.run.maxCallDepth
        guard task.callDepth < maxCallDepth else {
            throw RuntimeError("maximum call depth (\(maxCallDepth)) exceeded")
        }
        return MethodTarget(
            function: function,
            code: code,
            isClass: site.classType != nil,
            mapping: site.mapping
        )
    }

    /// The method `site` calls on an instance of `type`: the one method of that name it has or
    /// inherits, which takes these arguments as written and is one the loop can run.
    private func plainMethod(_ site: MethodSite, of type: ClassType) -> (Function?, Code?) {
        if site.isGetter {
            guard !Interpreter.namesSpecialMember(site.name),
                !type.allStored.contains(where: { $0.name == site.name }),
                let getter = type.computedProperty(site.name), !getter.isThrowing,
                getter.parameters.isEmpty, let code = compiled(getter), code.takesArgumentsAsWritten
            else { return (nil, nil) }
            site.mapping = nil
            return (getter, code)
        }
        let methods = type.allMethods(site.name)
        guard methods.count == 1, case let method = methods[0], !method.isThrowing,
            let mapping = argumentMapping(of: method, labels: site.labels),
            let code = compiled(method), code.takesArgumentsAsWritten
        else { return (nil, nil) }
        site.mapping = mapping.contains(-1) ? mapping : nil
        return (method, code)
    }

    /// The method `site` calls on a struct of the type of `record`, if it is the only one of that
    /// name, takes these arguments as written, and is one the loop can run (`Code.takesArgumentsAsWritten`).
    private func plainMethod(_ site: MethodSite, of record: Value.Record) -> (Function?, Code?) {
        if site.isGetter {
            guard !Interpreter.namesSpecialMember(site.name), record[site.name] == nil,
                let type = structType(of: record), let getter = type.members.computed[site.name],
                !getter.isThrowing, getter.parameters.isEmpty, let code = compiled(getter),
                code.takesArgumentsAsWritten
            else { return (nil, nil) }
            site.mapping = nil
            return (getter, code)
        }
        guard record[site.name] == nil, let type = structType(of: record),
            let methods = type.members.methods[site.name], methods.candidates.count == 1,
            case let method = methods.candidates[0], !method.isMutating || site.mayMutate,
            !method.isThrowing,
            let mapping = argumentMapping(of: method, labels: site.labels),
            let code = compiled(method), code.takesArgumentsAsWritten
        else { return (nil, nil) }
        site.mapping = mapping.contains(-1) ? mapping : nil
        return (method, code)
    }
}

extension Interpreter {
    /// Records at the site whether the next call by the same caller on the same type of struct is one the
    /// loop makes itself (`callMethod`): a method that undoes nothing as it returns, found for a struct,
    /// in the scopes the caller has.
    private func noteFastMethod(
        _ site: MethodSite,
        _ target: MethodTarget,
        from caller: Function,
        ownScope: Bool,
        extended: Bool
    ) {
        site.fastVersion = -1
        // A method that changes a struct is one the loop calls where the receiver is a local or a global
        // that it can move into the cell of `self`, and not `self`.
        let changes = target.function.isMutating && !target.isClass
        guard !site.isSuper, !site.isGetter, target.mapping == nil,
            !ownScope, site.sharesScopes, !extended,
            !target.code.isInitializerBody, !target.code.usesSuper,
            changes
                ? !site.receiverIsSelf && target.code.selfRegister != nil
                    && !target.code.selfByValue
                : !target.function.isMutating
                    && (target.code.selfRegister == nil || target.code.selfByValue),
            target.isClass ? site.classType != nil : site.type != nil
        else { return }
        site.fastChangesReceiver = changes
        site.fastFunction = .passUnretained(target.function)
        site.fastCode = .passUnretained(target.code)
        site.fastType = target.isClass ? nil : site.type
        site.fastClass = target.isClass ? site.classType : nil
        site.fastCaller = ObjectIdentifier(caller)
        site.fastVersion = scopeVersion
    }

    /// A call of a method the loop makes: when the site is one it can, the frame of the method is
    /// pushed and the cursor is that of its first instruction, and the caller's resumes after the code
    /// that makes the call the long way. False, with nothing done, otherwise.
    func enterMethod(
        _ site: MethodSite,
        _ operands: CallOperands,
        _ cursor: inout VMCursor,
        _ stack: VMStack
    ) throws -> Bool {
        let regs = stack.base + cursor.base
        let argumentBase = cursor.base + Int(operands.arguments)
        guard
            let target = try methodTarget(
                site,
                receiver: regs[Int(operands.receiver)],
                arguments: argumentBase,
                owner: cursor.function.owner
            )
        else { return false }
        var storeIn: Binding.Cell?
        // A method of a global that changes it puts the struct back in the global's cell, if it is a `var`.
        if let global = site.global {
            if !(global.version == scopeVersion
                && global.function == ObjectIdentifier(cursor.function))
            {
                findGlobal(global, cursor.function, cursor.code)
            }
            guard let cell = global.cell else { return false }
            if target.function.isMutating && !target.isClass {
                guard global.isMutable else { return false }
                storeIn = cell
            }
        }
        try checkInterrupt()
        if let mapping = target.mapping {
            try placeAndCheckArguments(mapping, of: target.function, at: argumentBase)
        }
        // A method whose body looks names up but has no register for `self` keeps the scope of its
        // own that it always had; any other runs in the scopes it captured.
        let ownScope = target.code.selfRegister == nil && target.code.looksUpNames
        // Whether it captured the scopes the caller did, which is worked out once for the site.
        if site.sharesCaller != ObjectIdentifier(cursor.function) {
            site.sharesCaller = ObjectIdentifier(cursor.function)
            site.sharesScopes =
                target.function.captured.count == cursor.code.capturedCount
                && task.scopes(are: target.function.captured)
        }
        let extended = task.scopes.count != cursor.code.capturedCount
        noteFastMethod(site, target, from: cursor.function, ownScope: ownScope, extended: extended)
        let saved: [Scope]? = ownScope || extended ? task.scopes : nil
        // A method of `self` that changes it puts the struct back in the cell of `self`.
        if site.receiverIsSelf, let register = cursor.code.selfRegister,
            case .object(let object) = stack.base[cursor.base + Int(register)].storage
        {
            storeIn = object as? Binding.Cell
        }
        let receiverValue = stack.base[cursor.base + Int(operands.receiver)]
        let exit: MethodExit
        if ownScope {
            exit = enterMethodScope(
                target,
                receiver: stack.base[cursor.base + Int(operands.receiver)],
                storeAt: cursor.base + Int(operands.receiver),
                storeIn: storeIn
            )
        } else {
            exit = enterLightMethod(
                target,
                receiver: receiverValue,
                storeAt: cursor.base + Int(operands.receiver),
                storeIn: storeIn
            )
            // The cell of `self` holds the struct alone while the method changes it, so that it is
            // changed where it is; it goes back where it came from as the method returns or fails.
            if exit.selfCell != nil, exit.storeReceiverAt >= 0 || exit.storeReceiverIn != nil {
                stack.base[cursor.base + Int(operands.receiver)] = .nothing
                exit.storeReceiverIn?.value = .nothing
            }
            if !site.sharesScopes || extended {
                setScopes(of: target.function, from: cursor.function, task)
            }
        }
        stack.push(
            VMCaller(
                code: cursor.code,
                function: cursor.function,
                callee: target.function,
                pc: cursor.pc + Int(operands.offset),
                base: cursor.base,
                statement: cursor.statement,
                destination: cursor.base + Int(operands.dst),
                isMethod: true
            ),
            scopes: saved
        )
        stack.methodExits.append(exit)
        stack.ensure(argumentBase + target.code.frameSize)
        stack.top = argumentBase + target.code.frameSize
        cursor = VMCursor(
            function: target.function,
            code: target.code,
            base: argumentBase,
            pc: 0,
            statement: -1
        )
        if let register = target.code.selfRegister {
            if let cell = exit.selfCell {
                stack.base[argumentBase + Int(register)] = .object(cell)
            } else if target.code.selfByValue {
                stack.base[argumentBase + Int(register)] = receiverValue
            }
        }
        return true
    }
}

extension Interpreter {
    /// `value.name` that is not a stored field: a computed property's getter entered as a frame (nil),
    /// or what `member(_:of:)` gives.
    func readMember(
        _ site: MethodSite,
        _ name: String,
        _ operands: CallOperands,
        _ cursor: inout VMCursor,
        _ stack: VMStack
    ) throws -> Value? {
        if try enterMethod(site, operands, &cursor, stack) { return nil }
        return try member(name, of: stack.base[cursor.base + Int(operands.receiver)])
    }
}

extension Interpreter {
    /// What returning from a method the loop called undoes (and, for an initializer, the value it gives): the class pushed for `super` is popped,
    /// and a struct the method changed goes back in the register it was called on.
    func finishMethod(_ exit: MethodExit, on stack: VMStack) throws -> Value? {
        if exit.popsOwner { task.owners.removeLast() }
        if let cell = exit.selfCell {
            if exit.storeReceiverAt >= 0 { stack.base[exit.storeReceiverAt] = cell.value }
            exit.storeReceiverIn?.value = cell.value
        }
        guard exit.isConstructor, let cell = exit.selfCell else { return nil }
        switch stack.completions.removeLast() {
        case .structValue(let type):
            guard let made = cell.value.record else {
                throw RuntimeError("\(type.name).init must leave self a \(type.name)")
            }
            // The fields set in the order the type declares them are the value as they are.
            if made.hasKeys(type.storedNames) { return Value(record: made) }
            var record = Value.Record(typeRef: type.typeRef, capacity: type.stored.count)
            for property in type.stored {
                guard let value = made[property.name] else {
                    throw RuntimeError("\(type.name).init must set '\(property.name)'")
                }
                record.appendDistinct(property.name, value)
            }
            return Value(record: record)
        case .classInstance(let instance, let initializer, let saved):
            defer { task.calledSuperInit = saved }
            try completeInitialization(of: instance, by: initializer)
            try checkAllSet(instance)
            return .object(instance)
        }
    }

    /// An error left a method's frame: what it pushed is undone, and nothing is stored.
    func abandonMethod(_ exit: MethodExit, on stack: VMStack) {
        if exit.popsOwner { task.owners.removeLast() }
        // What a mutating method changed before it failed is kept, as Swift keeps it.
        if !exit.isConstructor, let cell = exit.selfCell {
            if exit.storeReceiverAt >= 0 { stack.base[exit.storeReceiverAt] = cell.value }
            exit.storeReceiverIn?.value = cell.value
        }
        if exit.isConstructor, case .classInstance(_, _, let saved) = stack.completions.removeLast()
        {
            task.calledSuperInit = saved
        }
    }

    /// What a call of a method that runs in the scopes it captured leaves to undo: `self` is a cell in
    /// a register of the frame, for a body that names it, and the scope that binds it by name is made
    /// only if the body looks names up (`ensureSelfScope`).
    func enterLightMethod(
        _ target: MethodTarget,
        receiver: Value,
        storeAt: Int,
        storeIn: Binding.Cell?
    ) -> MethodExit {
        let cell =
            target.code.selfRegister == nil || target.code.selfByValue
            ? nil : Binding.Cell(receiver)
        // The class is pushed for `super`, which only a body that names it asks for.
        let owner = target.code.usesSuper && target.code.hasOwner ? target.function.owner : nil
        if let owner { task.owners.append(owner) }
        task.callDepth += 1
        let changes = cell != nil && target.function.isMutating && !target.isClass
        return MethodExit(
            selfCell: cell,
            popsOwner: owner != nil,
            storeReceiverAt: changes && storeIn == nil ? storeAt : -1,
            storeReceiverIn: changes ? storeIn : nil
        )
    }

    /// In the frame of a method, the scope that binds `self` by name, which what looks names up
    /// (a tree node, a closure) finds it in: made the first time, and kept until the method returns.
    @inline(__always)
    func ensureSelfScope(_ function: Function, _ code: Code, base: Int, on stack: VMStack) {
        if code.selfRegister != nil { makeSelfScope(function, code, base: base, on: stack) }
    }

    func makeSelfScope(_ function: Function, _ code: Code, base: Int, on stack: VMStack) {
        guard code.isMethodBody || code.isInitializerBody, let register = code.selfRegister,
            task.scopes.count == function.captured.count
        else { return }
        let held = stack.base[base + Int(register)]
        var binding: Binding
        if code.selfByValue {
            // The value of `self` was put in the register; a cell of its own is made for the scope.
            var mutable = false
            if case .object(is ClassInstance) = held.storage { mutable = true }
            binding = Binding(value: held, mutable: mutable)
        } else {
            guard case .object(let object) = held.storage, let cell = object as? Binding.Cell else {
                return
            }
            var mutable = function.isMutating || code.isInitializerBody
            if case .object(is ClassInstance) = cell.value.storage { mutable = true }
            binding = Binding(cell: cell, mutable: mutable)
            if code.isInitializerBody { binding.special = .initializing }
        }
        var table = BindingTable(capacity: 1)
        table["self"] = binding
        task.scopes = function.captured + [Scope(table: table)]
    }

    /// The scope a method call runs in, with `self` bound in it: after what the method captured.
    func enterMethodScope(
        _ target: MethodTarget,
        receiver: Value,
        storeAt: Int,
        storeIn: Binding.Cell?
    ) -> MethodExit {
        let binding = Binding(
            value: receiver,
            mutable: target.isClass || target.function.isMutating,
            special: nil
        )
        // A scope made for a call is seen by nothing made before it, so the names are not changed.
        var table = BindingTable(capacity: 1)
        table["self"] = binding
        let made = Scope(table: table)
        var inside = target.function.captured
        inside.append(made)
        task.scopes = inside
        // The class is pushed for `super`, which only a body that names it asks for.
        let owner = target.code.usesSuper && target.code.hasOwner ? target.function.owner : nil
        if let owner { task.owners.append(owner) }
        task.callDepth += 1
        return MethodExit(
            selfCell: binding.cell,
            popsOwner: owner != nil,
            storeReceiverAt: target.function.isMutating && !target.isClass && storeIn == nil
                ? storeAt : -1,
            storeReceiverIn: target.function.isMutating && !target.isClass ? storeIn : nil
        )
    }
}
