import Foundation

// The members of structs and classes the loop reads, sets and calls itself (`Docs/vm.md`).

extension Interpreter {
    /// Sets the field a site names of the struct `local` holds, in place, when its type allows that
    /// and `value` is of the kind the field holds. False, with nothing changed, otherwise.
    func setMember(
        _ site: MemberSite,
        _ local: inout Value,
        _ op: BinaryOperator?,
        _ value: Value
    ) -> Bool {
        if site.initializing { return setInitialMember(site, &local, op, value) }
        switch local.storage {
        case .structure(let structure):
            guard site.mutatesStruct, let typeRef = structure.record.typeRef else { return false }
            if site.version != scopeVersion || site.type != typeRef {
                site.version = scopeVersion
                site.type = typeRef
                site.classType = nil
                site.isDirect = isDirectlySettable(structure.record, site.name)
            }
            return site.isDirect && local.setField(site.name, op, value)
        case .object(let object):
            guard let instance = object as? ClassInstance else { return false }
            return setField(site, of: instance, op, value)
        default:
            return false
        }
    }

    /// `setMember` of the value a cell holds.
    func setMember(
        _ site: MemberSite,
        in cell: Binding.Cell,
        _ op: BinaryOperator?,
        _ value: Value
    ) -> Bool {
        var held = cell.value
        // A class's instance is changed where it is, and not moved out of the cell.
        if case .object = held.storage { return setMember(site, &held, op, value) }
        cell.value = .nothing
        defer { cell.value = held }
        return setMember(site, &held, op, value)
    }

    /// Sets a stored field of a class's instance where it is, when the class has no setter or observer
    /// for it, it is a `var`, and `value` is of the kind it holds.
    private func setField(
        _ site: MemberSite,
        of instance: ClassInstance,
        _ op: BinaryOperator?,
        _ value: Value
    ) -> Bool {
        let type = instance.type
        if site.version != scopeVersion || site.classType != ObjectIdentifier(type) {
            site.version = scopeVersion
            site.type = nil
            site.classType = ObjectIdentifier(type)
            site.isDirect =
                type.setter(site.name) == nil && type.observer(site.name) == nil
                && type.property(site.name)?.mutable == true
        }
        guard site.isDirect, let old = instance.storage[site.name],
            let new = Value.combined(old, op, value)
        else { return false }
        instance.storage[site.name] = new
        return true
    }

    /// Whether the field `name` of a value of the struct type of `record` may be set where it is: the
    /// tree evaluator's own conditions for changing a place in place (`plainPlace`).
    private func isDirectlySettable(_ record: Value.Record, _ name: String) -> Bool {
        guard let type = structType(of: record), type.members.setters[name] == nil,
            type.observers[name] == nil, let property = type.property(name), property.mutable
        else { return false }
        return extensionChain(of: Value(Value.Storage.structure(Value.Structure(record))))
            .allSatisfy { $0.setters[name] == nil }
    }
}

extension Value {
    /// What a field holding `old` is set to by `value`, or by `old op value`: `value` or the result of the
    /// operation when both are numbers, Bools or strings of one kind (an operation only on numbers). Nil
    /// for any other, which needs the conversion or the operator the general assignment has.
    static func combined(_ old: Value, _ op: BinaryOperator?, _ value: Value) -> Value? {
        switch (old.storage, value.storage) {
        case (.int(let x), .int(let y)):
            guard let op else { return value }
            guard let done = try? Interpreter.arithmetic(op, x, y), case .int = done.storage else {
                return nil
            }
            return done
        case (.double(let x), .double(let y)):
            switch op {
            case nil: return value
            case .add?: return .double(x + y)
            case .subtract?: return .double(x - y)
            case .multiply?: return .double(x * y)
            default: return nil
            }
        case (.bool, .bool), (.string, .string):
            return op == nil ? value : nil
        default:
            return nil
        }
    }

    /// Sets the stored field `name` of this struct to `value`, or to the result of `op` on what it
    /// holds and `value`, when the field holds a number, a Bool or a string and `value` is of that
    /// kind. The struct is changed where it is, not copied. False, with nothing changed, otherwise.
    mutating func setField(_ name: String, _ op: BinaryOperator?, _ value: Value) -> Bool {
        guard case .structure(var structure) = storage, let old = structure.record[name],
            let result = Value.combined(old, op, value)
        else { return false }
        storage = .nothing
        structure.record[name] = result
        storage = .structure(structure)
        return true
    }
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
                guard let typeRef = structure.record.typeRef else { return nil }
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

    /// What returning from a method the loop called undoes: the class pushed for `super` is popped,
    /// and a struct the method changed goes back in the register it was called on.
    func finishMethod(_ exit: MethodExit, on stack: VMStack) {
        if exit.popsOwner { task.owners.removeLast() }
        if exit.storeReceiverAt >= 0 { stack.base[exit.storeReceiverAt] = exit.selfCell.value }
    }

    /// The scope a method call runs in, with `self` bound in it: after what the method captured.
    func enterMethodScope(_ target: MethodTarget, receiver: Value, storeAt: Int) -> MethodExit {
        let made = Scope()
        let binding = Binding(
            value: receiver,
            mutable: target.isClass || target.function.isMutating,
            special: nil
        )
        made.bindings["self"] = binding
        var inside = target.function.captured
        inside.append(made)
        task.scopes = inside
        if let owner = target.function.owner { task.owners.append(owner) }
        task.callDepth += 1
        return MethodExit(
            selfCell: binding.cell,
            popsOwner: target.function.owner != nil,
            storeReceiverAt: target.function.isMutating && !target.isClass ? storeAt : -1
        )
    }

    /// The method `site` calls on an instance of `type`: the one method of that name it has or
    /// inherits, which takes these arguments as written and is one the loop can run.
    private func plainMethod(_ site: MethodSite, of type: ClassType) -> (Function?, Code?) {
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
    /// `self.name = value` in an initializer, of a struct or a class's instance: the field is set where
    /// it is, made if it is not there yet, with the value conformed to the type it is declared with, as
    /// the general assignment of an initializer does. A compound assignment is for a field that holds a
    /// number of the kind already. False, with nothing changed, where the general one is needed.
    func setInitialMember(
        _ site: MemberSite,
        _ local: inout Value,
        _ op: BinaryOperator?,
        _ value: Value
    ) -> Bool {
        switch local.storage {
        case .structure(let structure):
            guard let typeRef = structure.record.typeRef else { return false }
            if site.version != scopeVersion || site.type != typeRef {
                site.version = scopeVersion
                site.type = typeRef
                site.classType = nil
                let type = structType(of: structure.record)
                site.isDirect =
                    type?.members.setters[site.name] == nil && type?.property(site.name) != nil
                    && extensionChain(of: Value(Value.Storage.structure(structure)))
                        .allSatisfy { $0.setters[site.name] == nil }
                site.propertyType = type?.property(site.name)?.type
            }
            guard site.isDirect, let stored = initialValue(site, op, value) else { return false }
            return local.setStoredField(site.name, stored)
        case .object(let object):
            guard let instance = object as? ClassInstance else { return false }
            let type = instance.type
            if site.version != scopeVersion || site.classType != ObjectIdentifier(type) {
                site.version = scopeVersion
                site.type = nil
                site.classType = ObjectIdentifier(type)
                let property = type.property(site.name)
                site.isDirect =
                    type.setter(site.name) == nil && property != nil && property?.isWeak == false
                    && property?.isLazy == false
                site.propertyType = property?.type
            }
            guard site.isDirect, let stored = initialValue(site, op, value) else { return false }
            if op != nil, instance.storage[site.name] == nil { return false }
            instance.storage[site.name] = stored
            return true
        default:
            return false
        }
    }

    /// What the field a site sets holds after `op` and `value`, conformed to its declared type.
    private func initialValue(
        _ site: MemberSite,
        _ op: BinaryOperator?,
        _ value: Value
    ) -> Value? {
        guard op == nil else { return nil }
        guard let type = site.propertyType else { return value }
        return conform(value, to: type)
    }
}

extension Value {
    /// Sets the field `name` of this struct to `value`, adding it if it is not there. In place.
    mutating func setStoredField(_ name: String, _ value: Value) -> Bool {
        guard case .structure(var structure) = storage else { return false }
        storage = .nothing
        structure.record[name] = value
        storage = .structure(structure)
        return true
    }
}

extension Interpreter {
    /// `Point(x: 1, y: 2)` of a struct or `Dog(name: "Rex")` of a class, made from the registers from `arguments` on, when the type is
    /// plain: the memberwise initializer taking every field, or one initializer of its own that takes
    /// its arguments as written and does not fail. The value is what `construct` makes of the same
    /// arguments; nil, with nothing done, where the site is not that, which `construct` then makes.
    func constructValue(
        _ site: CallSite,
        from function: Function,
        arguments: Int
    ) throws -> Value? {
        guard let name = site.name else { return nil }
        if site.constructedVersion != scopeVersion
            || site.constructedCaller != ObjectIdentifier(function)
        {
            site.constructedVersion = scopeVersion
            site.constructedCaller = ObjectIdentifier(function)
            site.constructedType = nil
            site.constructedClass = nil
            site.constructedInitializer = nil
            site.constructedCode = nil
            switch lookup(name)?.value.storage {
            case .object(let type as StructType)?: site.constructedType = type
            case .object(let type as ClassType)?: findClassInitializer(of: type, site)
            default: break
            }
        }
        if let type = site.constructedClass { return try constructClass(type, site, arguments) }
        guard let type = site.constructedType, typeExtensions[type.name]?.initializers == nil
        else { return nil }
        let made: Value
        if let initializers = type.members.initializers {
            guard let value = try constructWithInitializer(type, initializers, site, arguments)
            else { return nil }
            made = value
        } else {
            guard let value = constructMemberwise(type, site, arguments) else { return nil }
            made = value
        }
        let stack = task.vm
        for index in 0..<site.labels.count { stack.base[arguments + index] = .nothing }
        return made
    }

    /// The memberwise initializer, when the call gives every field in order, each as its type has it.
    private func constructMemberwise(
        _ type: StructType,
        _ site: CallSite,
        _ arguments: Int
    ) -> Value? {
        let parameters = type.memberwise.parameters
        guard parameters.count == site.labels.count, parameters.count == type.stored.count,
            zip(parameters, site.labels).allSatisfy({ $0.label == $1 })
        else { return nil }
        let stack = task.vm
        var record = Value.Record(typeRef: type.typeRef)
        record.reserveCapacity(parameters.count)
        for (index, parameter) in parameters.enumerated() {
            let value = stack.base[arguments + index]
            guard
                let stored = ParameterKind(parameter.type).accepts(value)
                    ? value : conform(value, to: parameter.type)
            else { return nil }
            record[parameter.name] = stored
        }
        // In the order the type declares them.
        var ordered = Value.Record(typeRef: type.typeRef)
        ordered.reserveCapacity(parameters.count)
        for property in type.stored {
            guard let value = record[property.name] else { return nil }
            ordered[property.name] = value
        }
        return Value(record: ordered)
    }

    /// An initializer of the type's own, run from the registers: the defaults are the start of the
    /// value, the initializer sets the rest, and the fields are put in declaration order.
    private func constructWithInitializer(
        _ type: StructType,
        _ initializers: OverloadSet,
        _ site: CallSite,
        _ arguments: Int
    ) throws -> Value? {
        guard initializers.candidates.count == 1, case let initializer = initializers.candidates[0],
            !initializer.isFailable, !initializer.isConvenience,
            initializer.parameters.count == site.labels.count,
            zip(initializer.parameters, site.labels).allSatisfy({ $0.label == $1 }),
            let code = compiled(initializer), code.takesArgumentsAsWritten
        else { return nil }
        let stack = task.vm
        for index in 0..<code.parameterCount
        where !code.parameterKinds[index].accepts(at: stack.base + arguments + index) {
            return nil
        }
        let maxCallDepth = task.run.maxCallDepth
        guard task.callDepth < maxCallDepth else {
            throw RuntimeError("maximum call depth (\(maxCallDepth)) exceeded")
        }
        var start = Value.Record(typeRef: type.typeRef)
        start.reserveCapacity(type.stored.count)
        for property in type.stored {
            if let defaultValue = property.defaultValue {
                start[property.name] = try storedValue(defaultValue, for: property, of: type)
            }
        }
        let receiver = Receiver(Value(record: start), mutable: true, initializing: true)
        task.failedInit = false
        try checkInterrupt()
        defer { task.lastCallee = initializer }
        _ = try runCompiled(
            initializer,
            code,
            with: [:],
            receiver: receiver,
            argumentsAt: arguments
        )
        guard let made = receiver.value.record else {
            throw RuntimeError("\(type.name).init must leave self a \(type.name)")
        }
        var record = Value.Record(typeRef: type.typeRef)
        record.reserveCapacity(type.stored.count)
        for property in type.stored {
            guard let value = made[property.name] else {
                throw RuntimeError("\(type.name).init must set '\(property.name)'")
            }
            record[property.name] = value
        }
        return Value(record: record)
    }
}

extension Interpreter {
    /// What a site that makes an instance of `type` runs: its one initializer, when it has just one that
    /// is designated, not failable and takes the call's arguments as written, or none when the call has
    /// no arguments. The site keeps the class only when that is so.
    private func findClassInitializer(of type: ClassType, _ site: CallSite) {
        let candidates = initializers(of: type)
        if candidates.isEmpty {
            if site.labels.isEmpty { site.constructedClass = type }
            return
        }
        guard candidates.count == 1, case let initializer = candidates[0],
            !initializer.isFailable, !initializer.isConvenience,
            initializer.parameters.count == site.labels.count,
            zip(initializer.parameters, site.labels).allSatisfy({ $0.label == $1 }),
            let code = compiled(initializer), code.takesArgumentsAsWritten
        else { return }
        site.constructedClass = type
        site.constructedInitializer = initializer
        site.constructedCode = code
    }

    /// An instance of `type`, made as `construct` makes one: its properties start as they are declared,
    /// the initializer runs on it from the registers, and each property must be set after.
    private func constructClass(
        _ type: ClassType,
        _ site: CallSite,
        _ arguments: Int
    ) throws -> Value? {
        let stack = task.vm
        if let code = site.constructedCode {
            for index in 0..<code.parameterCount
            where !code.parameterKinds[index].accepts(at: stack.base + arguments + index) {
                return nil
            }
        }
        let maxCallDepth = task.run.maxCallDepth
        guard task.callDepth < maxCallDepth else {
            throw RuntimeError("maximum call depth (\(maxCallDepth)) exceeded")
        }
        let instance = ClassInstance(type: type)
        for property in type.allStored {
            if let value = try initialValue(of: property) {
                instance.storage[property.name] = value
            }
        }
        if type.chain.contains(where: { $0.deinitializer != nil }) {
            instance.onRelease = { [weak self] released in self?.release(released) }
        }
        if let initializer = site.constructedInitializer, let code = site.constructedCode {
            task.failedInit = false
            try initialize(instance, with: initializer) { receiver in
                try self.checkInterrupt()
                defer { self.task.lastCallee = initializer }
                _ = try self.runCompiled(
                    initializer,
                    code,
                    with: [:],
                    receiver: receiver,
                    argumentsAt: arguments
                )
            }
        }
        for property in type.allStored
        where instance.storage[property.name] == nil && !property.isLazy {
            throw RuntimeError("\(type.name).init must set '\(property.name)'")
        }
        for index in 0..<site.labels.count { stack.base[arguments + index] = .nothing }
        return .object(instance)
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

/// The registers a `callMethod` instruction names.
struct CallOperands {
    let dst: Register
    let receiver: Register
    let arguments: Register
    let offset: Int32
}

extension Interpreter {
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
        try checkInterrupt()
        if let mapping = target.mapping {
            try placeAndCheckArguments(mapping, of: target.function, at: argumentBase)
        }
        let saved = task.scopes
        let exit = enterMethodScope(
            target,
            receiver: stack.base[cursor.base + Int(operands.receiver)],
            storeAt: cursor.base + Int(operands.receiver)
        )
        stack.callers.append(
            VMCaller(
                code: cursor.code,
                function: cursor.function,
                callee: target.function,
                pc: cursor.pc + Int(operands.offset),
                base: cursor.base,
                statement: cursor.statement,
                destination: cursor.base + Int(operands.dst),
                scopes: saved,
                sameScopes: false,
                isMethod: true
            )
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
            stack.base[argumentBase + Int(register)] = .object(CellBox(cell: exit.selfCell))
        }
        return true
    }
}
