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
        // Nothing here holds the struct while it is set, so that it is set where it is.
        if let typeRef = local.structTypeRef {
            guard site.mutatesStruct else { return false }
            if site.version != scopeVersion || site.type != typeRef {
                site.version = scopeVersion
                site.type = typeRef
                site.classType = nil
                site.isDirect = local.record.map { isDirectlySettable($0, site.name) } ?? false
            }
            return site.isDirect && local.setField(site.name, op, value)
        }
        if case .object(let object) = local.storage, let instance = object as? ClassInstance {
            return setField(site, of: instance, op, value)
        }
        return false
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
        guard case .structure(var structure) = storage, let old = structure[name],
            let result = Value.combined(old, op, value)
        else { return false }
        storage = .nothing
        structure[name] = result
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

    /// What returning from a method the loop called undoes (and, for an initializer, the value it gives): the class pushed for `super` is popped,
    /// and a struct the method changed goes back in the register it was called on.
    func finishMethod(_ exit: MethodExit, on stack: VMStack) throws -> Value? {
        if exit.popsOwner { task.owners.removeLast() }
        if exit.storeReceiverAt >= 0 { stack.base[exit.storeReceiverAt] = exit.selfCell.value }
        exit.storeReceiverIn?.value = exit.selfCell.value
        guard exit.isConstructor else { return nil }
        switch stack.completions.removeLast() {
        case .structValue(let type):
            guard let made = exit.selfCell.value.record else {
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
        if exit.isConstructor, case .classInstance(_, _, let saved) = stack.completions.removeLast()
        {
            task.calledSuperInit = saved
        }
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
        if let owner = target.function.owner { task.owners.append(owner) }
        task.callDepth += 1
        return MethodExit(
            selfCell: binding.cell,
            popsOwner: target.function.owner != nil,
            storeReceiverAt: target.function.isMutating && !target.isClass && storeIn == nil
                ? storeAt : -1,
            storeReceiverIn: target.function.isMutating && !target.isClass ? storeIn : nil
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
        // The struct is not held here while it is set, so that it is set where it is.
        if let typeRef = local.structTypeRef {
            if site.version != scopeVersion || site.type != typeRef {
                site.version = scopeVersion
                site.type = typeRef
                site.classType = nil
                let record = local.record
                let type = record.flatMap { structType(of: $0) }
                site.isDirect =
                    type?.members.setters[site.name] == nil && type?.property(site.name) != nil
                    && extensionChain(of: local).allSatisfy { $0.setters[site.name] == nil }
                site.propertyType = type?.property(site.name)?.type
            }
            guard site.isDirect, let stored = initialValue(site, op, value) else { return false }
            return local.setStoredField(site.name, stored)
        }
        switch local.storage {
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
        structure[name] = value
        storage = .structure(structure)
        return true
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
        let saved = task.scopes
        // A method of `self` that changes it puts the struct back in the cell of `self`.
        if site.receiverIsSelf, let register = cursor.code.selfRegister,
            case .object(let object) = stack.base[cursor.base + Int(register)].storage
        {
            storeIn = object as? Binding.Cell
        }
        let exit = enterMethodScope(
            target,
            receiver: stack.base[cursor.base + Int(operands.receiver)],
            storeAt: cursor.base + Int(operands.receiver),
            storeIn: storeIn
        )
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
            stack.base[argumentBase + Int(register)] = .object(exit.selfCell)
        }
        return true
    }
}

extension Interpreter {
    /// A member of a Swift type run as the tree evaluator runs it, with the receiver and the arguments
    /// (in the registers from `arguments` on) taken as they are.
    func callBridged(_ site: BridgedSite, receiver: Value?, arguments: Int) throws -> Value {
        let stack = task.vm
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

extension Interpreter {
    /// A call of a name that is not a function the loop enters: the value of a struct or a class made
    /// from the registers, or by the tree evaluator's call; nil where an initializer's frame was entered,
    /// which makes it when it returns.
    func constructOrCall(
        _ call: ConstructCall,
        _ cursor: inout VMCursor,
        _ stack: VMStack
    ) throws -> Value? {
        switch try construct(call, &cursor, stack) {
        case .made(let value): return value
        case .entered: return nil
        case .none: return try evaluateCall(call.site, call.site.callee, call.argumentBase)
        }
    }

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

extension Value {
    /// The type of the struct this is, if it is one: found without holding the struct.
    var structTypeRef: TypeRef? {
        if case .structure(let structure) = storage { return structure.typeRefIfAny }
        return nil
    }
}

extension Interpreter {
    /// A list's or a string's member (`append`, `count`, a subscript) of a global, where the global's
    /// cell holds the value: read there, or, for `append`, changed there. Nil, with nothing changed, where
    /// the kinds do not fit, which the tree evaluator then does.
    func fastGlobalMember(
        _ kind: FastMember,
        _ site: GlobalSite,
        _ function: Function,
        _ code: Code,
        _ argument: Value
    ) throws -> Value? {
        if !(site.version == scopeVersion && site.function == ObjectIdentifier(function)) {
            findGlobal(site, function, code)
        }
        guard let cell = site.cell else { return nil }
        switch kind {
        case .append:
            guard site.isMutable, cell.value.isList(likeElement: argument) else { return nil }
            try checkInterrupt()
            // Taken out of the cell, so that it is changed where it is and not copied.
            var held = cell.value
            cell.value = .nothing
            _ = held.appendLikeElements(argument)
            cell.value = held
            return .nothing
        default:
            guard let value = FastMember.read(kind, cell.value, argument) else { return nil }
            if kind.takesStep { try checkInterrupt() }
            return value
        }
    }

    /// `name.field = value` or `name.field op= value` of a global holding a struct or an instance, set
    /// in the cell as `setMember` sets a local's. False, with nothing changed, otherwise.
    func setGlobalMember(
        _ site: GlobalSite,
        _ member: MemberSite,
        _ function: Function,
        _ code: Code,
        _ assignment: (op: BinaryOperator?, value: Value)
    ) throws -> Bool {
        if !(site.version == scopeVersion && site.function == ObjectIdentifier(function)) {
            findGlobal(site, function, code)
        }
        guard site.isMutable, let cell = site.cell else { return false }
        return setMember(member, in: cell, assignment.op, assignment.value)
    }
}

extension Value {
    /// Sets the element of this list or dictionary at `key` to `value`, or to the result of `op` on what
    /// it holds (`fallback` if the dictionary has nothing there) and `value`, when the kinds fit: an
    /// index of a list within it, and numbers, Bools or strings of one kind. The collection is
    /// changed where it is, not copied. False, with nothing changed, otherwise.
    mutating func setElement(
        _ key: Value,
        _ fallback: Value?,
        _ op: BinaryOperator?,
        _ value: Value
    ) -> Bool {
        // Nothing is bound while the collection is tested, so that it is changed where it is.
        if case .list = storage { return setListElement(key, fallback, op, value) }
        if case .dictionary = storage { return setDictionaryElement(key, fallback, op, value) }
        return false
    }

    private mutating func setListElement(
        _ key: Value,
        _ fallback: Value?,
        _ op: BinaryOperator?,
        _ value: Value
    ) -> Bool {
        guard fallback == nil, case .int(let index) = key.storage,
            case .list(var items) = storage, items.indices.contains(index)
        else { return false }
        let new: Value
        if let op {
            guard let combined = Value.combined(items[index], op, value) else { return false }
            new = combined
        } else {
            new = value
        }
        storage = .nothing
        items[index] = new
        storage = .list(items)
        return true
    }

    private mutating func setDictionaryElement(
        _ key: Value,
        _ fallback: Value?,
        _ op: BinaryOperator?,
        _ value: Value
    ) -> Bool {
        guard case .dictionary(var dictionary) = storage else { return false }
        let new: Value
        if let op {
            guard let current = dictionary[key] ?? fallback, current != .nothing,
                let combined = Value.combined(current, op, value)
            else { return false }
            new = combined
        } else {
            guard fallback == nil else { return false }
            new = value
        }
        storage = .nothing
        dictionary[key] = new == .nothing ? nil : new
        storage = .dictionary(dictionary)
        return true
    }
}
