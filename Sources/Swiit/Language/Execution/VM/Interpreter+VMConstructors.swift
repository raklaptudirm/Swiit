import Foundation

// Making a struct or an instance from the registers, or by entering the frame of its initializer
// (`Docs/vm.md`).

extension Interpreter {
    /// `Point(x: 1, y: 2)` of a struct or `Dog(name: "Rex")` of a class, made from the registers from `arguments` on, when the type is
    /// plain: the memberwise initializer taking every field, or one initializer of its own that takes
    /// its arguments as written and does not fail. The value is what `construct` makes of the same
    /// arguments; nil, with nothing done, where the site is not that, which `construct` then makes.
    func construct(
        _ call: ConstructCall,
        _ cursor: inout VMCursor,
        _ stack: VMStack
    ) throws -> Construction {
        let site = call.site
        guard let name = site.name else { return .none }
        let function = cursor.function
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
        if let type = site.constructedClass {
            return try constructClass(type, call, &cursor, stack)
        }
        guard let type = site.constructedType, typeExtensions[type.name]?.initializers == nil
        else { return .none }
        if let initializers = type.members.initializers {
            return try constructWithInitializer(type, initializers, call, &cursor, stack)
        }
        guard let value = constructMemberwise(type, site, call.argumentBase) else { return .none }
        clearArguments(call)
        return .made(value)
    }

    private func clearArguments(_ call: ConstructCall) {
        let stack = task.vm
        for index in 0..<call.site.labels.count { stack.base[call.argumentBase + index] = .nothing }
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

    /// An initializer of the type's own, entered as a frame of the loop: the defaults are the start of the
    /// value, the initializer sets the rest, and the fields are put in declaration order when it
    /// returns (`finishMethod`).
    private func constructWithInitializer(
        _ type: StructType,
        _ initializers: OverloadSet,
        _ call: ConstructCall,
        _ cursor: inout VMCursor,
        _ stack: VMStack
    ) throws -> Construction {
        let site = call.site
        // The one it has, or the one the checker chose among several, as `narrowed` takes it.
        let candidates = initializers.candidates
        let chosen = candidates.count == 1 ? 0 : site.overload
        guard let chosen, candidates.indices.contains(chosen),
            case let initializer = candidates[chosen],
            !initializer.isFailable, !initializer.isConvenience,
            initializer.parameters.count == site.labels.count,
            zip(initializer.parameters, site.labels).allSatisfy({ $0.label == $1 }),
            let code = compiled(initializer), code.takesArgumentsAsWritten
        else { return .none }
        for index in 0..<code.parameterCount
        where !code.parameterKinds[index].accepts(at: stack.base + call.argumentBase + index) {
            return .none
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
        task.failedInit = false
        try checkInterrupt()
        pushConstructor(
            ConstructorFrame(
                initializer: initializer,
                code: code,
                receiver: Value(record: start),
                completion: .structValue(type)
            ),
            call,
            &cursor,
            stack
        )
        return .entered
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
    /// the initializer is entered as a frame of the loop on it, and each property must be set when it
    /// returns (`finishMethod`).
    private func constructClass(
        _ type: ClassType,
        _ call: ConstructCall,
        _ cursor: inout VMCursor,
        _ stack: VMStack
    ) throws -> Construction {
        let site = call.site
        if let code = site.constructedCode {
            for index in 0..<code.parameterCount
            where !code.parameterKinds[index].accepts(at: stack.base + call.argumentBase + index) {
                return .none
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
        guard let initializer = site.constructedInitializer, let code = site.constructedCode else {
            try checkAllSet(instance)
            clearArguments(call)
            return .made(.object(instance))
        }
        task.failedInit = false
        try checkInterrupt()
        let saved = task.calledSuperInit
        task.calledSuperInit = false
        pushConstructor(
            ConstructorFrame(
                initializer: initializer,
                code: code,
                receiver: .object(instance),
                completion: .classInstance(instance, initializer, savedSuperInit: saved)
            ),
            call,
            &cursor,
            stack
        )
        return .entered
    }

    /// Every stored property of an instance must have been set, but a `lazy` one.
    func checkAllSet(_ instance: ClassInstance) throws {
        for property in instance.type.allStored
        where instance.storage[property.name] == nil && !property.isLazy {
            throw RuntimeError("\(instance.type.name).init must set '\(property.name)'")
        }
    }

    /// Pushes the frame of an initializer, run on `receiver` with `self` bound as it is made, and moves
    /// the cursor to its first instruction. Returning from it gives what `completion` makes.
    private func pushConstructor(
        _ frame: ConstructorFrame,
        _ call: ConstructCall,
        _ cursor: inout VMCursor,
        _ stack: VMStack
    ) {
        let (initializer, code, receiver, completion) =
            (frame.initializer, frame.code, frame.receiver, frame.completion)
        let made = Scope()
        let binding = Binding(value: receiver, mutable: true, special: .initializing)
        made.bindings["self"] = binding
        let saved = task.scopes
        var inside = initializer.captured
        inside.append(made)
        task.scopes = inside
        if let owner = initializer.owner { task.owners.append(owner) }
        task.callDepth += 1
        stack.callers.append(
            VMCaller(
                code: cursor.code,
                function: cursor.function,
                callee: initializer,
                pc: cursor.pc,
                base: cursor.base,
                statement: cursor.statement,
                destination: cursor.base + Int(call.dst),
                scopes: saved,
                sameScopes: false,
                isMethod: true
            )
        )
        stack.methodExits.append(
            MethodExit(
                selfCell: binding.cell,
                popsOwner: initializer.owner != nil,
                storeReceiverAt: -1,
                completion: completion
            )
        )
        stack.ensure(call.argumentBase + code.frameSize)
        stack.top = call.argumentBase + code.frameSize
        cursor = VMCursor(
            function: initializer,
            code: code,
            base: call.argumentBase,
            pc: 0,
            statement: -1
        )
        if let register = code.selfRegister {
            stack.base[call.argumentBase + Int(register)] = .object(CellBox(cell: binding.cell))
        }
    }
}

/// A call of a name that may make a value: the site, the register its result goes to, and where its
/// arguments are, counted from the stack's start.
struct ConstructCall {
    let site: CallSite
    let dst: Register
    let argumentBase: Int
}

/// What a call that may make a value did: nothing, made it from the registers, or entered the frame of
/// an initializer that will.
enum Construction {
    case none
    case made(Value)
    case entered
}
extension Interpreter {
    /// A member name `member(_:of:)` answers before it looks at the type's own computed properties.
    static func namesSpecialMember(_ name: String) -> Bool {
        name == "description" || name == "debugDescription" || name == "localizedDescription"
    }
}

/// The initializer a constructor enters, the value it runs on, and what it makes when it returns.
struct ConstructorFrame {
    let initializer: Function
    let code: Code
    let receiver: Value
    let completion: MethodExit.Completion
}
