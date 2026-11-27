import Foundation

// Making a struct or an instance from the registers, or by entering the frame of its initializer
// (`Docs/vm.md`).

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

/// The initializer a constructor enters, the value it runs on, and what it makes when it returns.
struct ConstructorFrame {
    let initializer: Function
    let code: Code
    let receiver: Value
    let completion: MethodExit.Completion
}

/// What a struct's memberwise initializer does with each argument: which stored property takes it, and
/// how it is checked.
final class MemberwisePlan {
    /// The labels of the parameters, in the order a call gives its arguments.
    let labels: [String?]
    /// For each stored property, in declaration order, the argument it takes.
    let slots: [Int]
    let kinds: [ParameterKind]
    let types: [TypeExpression]
    let keys: [String]

    init(
        labels: [String?],
        slots: [Int],
        kinds: [ParameterKind],
        types: [TypeExpression],
        keys: [String]
    ) {
        self.labels = labels
        self.slots = slots
        self.kinds = kinds
        self.types = types
        self.keys = keys
    }
}

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
            site.memberwisePlan = nil
            switch lookup(name)?.value.storage {
            case .object(let type as StructType)?:
                site.constructedType = type
                if type.members.initializers == nil, typeExtensions[type.name]?.initializers == nil,
                    let plan = memberwisePlan(of: type), plan.labels == site.labels
                {
                    site.memberwisePlan = plan
                }
            case .object(let type as ClassType)?: findClassInitializer(of: type, site)
            default: break
            }
        }
        if let type = site.constructedClass {
            return try constructClass(type, call, &cursor, stack)
        }
        if let plan = site.memberwisePlan, let type = site.constructedType,
            let value = constructMemberwise(type, plan, call.argumentBase)
        {
            return .made(value)
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

    /// Whether `initializer` takes the labels the call gives, remembered at the site.
    private func takesLabels(of site: CallSite, _ initializer: Function) -> Bool {
        if site.fittedInitializer === initializer { return true }
        guard initializer.parameters.count == site.labels.count,
            zip(initializer.parameters, site.labels).allSatisfy({ $0.label == $1 })
        else { return false }
        site.fittedInitializer = initializer
        return true
    }

    /// The memberwise initializer, when the call gives every field, each as its type has it.
    /// The value of a memberwise initializer whose arguments are all of the kinds the fields hold: the
    /// arguments, which are left holding nothing, are the fields. Nil, with nothing changed, where one
    /// is not.
    private func constructMemberwise(
        _ type: StructType,
        _ plan: MemberwisePlan,
        _ arguments: Int
    ) -> Value? {
        let registers = task.vm.base + arguments
        for index in plan.keys.indices
        where !plan.kinds[index].accepts(at: registers + plan.slots[index]) {
            return nil
        }
        return Value(
            record: Value.Record(
                typeRef: type.typeRef,
                keys: plan.keys,
                taking: registers,
                at: plan.slots
            )
        )
    }

    private func constructMemberwise(
        _ type: StructType,
        _ site: CallSite,
        _ arguments: Int
    ) -> Value? {
        guard let plan = memberwisePlan(of: type), plan.labels == site.labels else { return nil }
        let stack = task.vm
        var record = Value.Record(typeRef: type.typeRef, capacity: plan.keys.count)
        for index in plan.keys.indices {
            let value = stack.base[arguments + plan.slots[index]]
            guard
                let stored = plan.kinds[index].accepts(value)
                    ? value : conform(value, to: plan.types[index])
            else { return nil }
            record.appendDistinct(plan.keys[index], stored)
        }
        // In the order the type declares them.
        return Value(record: record)
    }

    /// The plan of the memberwise initializer of `type`, or nil when it is not one that takes each
    /// stored property once, by its name.
    private func memberwisePlan(of type: StructType) -> MemberwisePlan? {
        if type.hasMemberwisePlan { return type.memberwisePlan }
        type.hasMemberwisePlan = true
        let parameters = type.memberwise.parameters
        guard parameters.count == type.stored.count else { return nil }
        var slots: [Int] = []
        for property in type.stored {
            guard let index = parameters.firstIndex(where: { $0.name == property.name }) else {
                return nil
            }
            slots.append(index)
        }
        guard Set(slots).count == slots.count else { return nil }
        type.memberwisePlan = MemberwisePlan(
            labels: parameters.map(\.label),
            slots: slots,
            kinds: slots.map { ParameterKind(parameters[$0].type) },
            types: slots.map { parameters[$0].type },
            keys: type.stored.map(\.name)
        )
        return type.memberwisePlan
    }

    /// The record a new value of `type` starts as, before an initializer sets the rest: the defaults, which
    /// are the same each time when they are all literals.
    private func startingRecord(of type: StructType) throws -> Value.Record {
        if !type.hasStartingFields {
            type.hasStartingFields = true
            let literals = type.stored.allSatisfy { property in
                guard let defaultValue = property.defaultValue else { return true }
                if case .literal(let literal) = defaultValue {
                    return property.type.map({ ParameterKind($0).accepts(literal) }) ?? true
                }
                return false
            }
            if literals {
                var fields = Value.Record(typeRef: type.typeRef, capacity: type.stored.count)
                for property in type.stored {
                    if case .literal(let literal)? = property.defaultValue {
                        fields.appendDistinct(property.name, literal)
                    }
                }
                type.startingFields = fields
            }
        }
        if let fields = type.startingFields { return fields.cloned(capacity: type.stored.count) }
        var start = Value.Record(typeRef: type.typeRef, capacity: type.stored.count)
        for property in type.stored {
            if let defaultValue = property.defaultValue {
                start[property.name] = try storedValue(defaultValue, for: property, of: type)
            }
        }
        return start
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
            takesLabels(of: site, initializer),
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
        let start = try startingRecord(of: type)
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
        let plan = type.instancePlan
        let instance = ClassInstance(type: type, storage: FieldTable(capacity: plan.names.count))
        for index in plan.names.indices {
            switch plan.starts[index] {
            case .absent: continue
            case .value(let value): instance.storage[plan.names[index]] = value
            case .evaluated:
                if let value = try initialValue(of: type.allStored[index]) {
                    instance.storage[plan.names[index]] = value
                }
            }
        }
        if plan.hasDeinit {
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
        for name in instance.plan.required where instance.storage[name] == nil {
            throw RuntimeError("\(instance.type.name).init must set '\(name)'")
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
        // An initializer whose body looks names up but has no register for `self` keeps the scope of
        // its own that it always had; any other runs in the scopes it captured, and the scope that
        // binds `self` by name is made when something looks for it (`ensureSelfScope`).
        let ownScope = code.selfRegister == nil && code.looksUpNames
        // Whether it captured the scopes the caller did, which is worked out once for the site.
        let site = call.site
        if site.sharesCaller != ObjectIdentifier(cursor.function)
            || site.sharesInitializer != ObjectIdentifier(initializer)
        {
            site.sharesCaller = ObjectIdentifier(cursor.function)
            site.sharesInitializer = ObjectIdentifier(initializer)
            site.sharesScopes =
                initializer.captured.count == cursor.code.capturedCount
                && task.scopes(are: initializer.captured)
        }
        let extended = task.scopes.count != cursor.code.capturedCount
        let saved: [Scope]? = ownScope || extended ? task.scopes : nil
        let held: HeldSelf
        if ownScope {
            held = bindSelfInScope(receiver, of: initializer, mutable: true, special: .initializing)
        } else {
            held = .made(receiver, as: code.selfStorage)
            if !site.sharesScopes || extended {
                setScopes(of: initializer, from: cursor.function, task)
            }
        }
        enterMethodFrame(
            MethodFrame(
                function: initializer,
                code: code,
                argumentBase: call.argumentBase,
                resumeAt: cursor.pc,
                destination: cursor.base + Int(call.dst),
                savedScopes: saved,
                held: held,
                ending: .initializer(completion)
            ),
            &cursor,
            stack
        )
    }
}

extension Interpreter {
    /// A member name `member(_:of:)` answers before it looks at the type's own computed properties.
    static func namesSpecialMember(_ name: String) -> Bool {
        name == "description" || name == "debugDescription" || name == "localizedDescription"
    }
}

extension Interpreter {
    /// `constructOrCall` from the loop, which may look names up (`self`, for one): a function of its
    /// own, so that what that needs is not in the loop.
    @inline(never)
    func constructOrCallLookingUp(
        _ call: ConstructCall,
        _ cursor: inout VMCursor,
        _ stack: VMStack
    ) throws -> Value? {
        let (function, code, base) = (cursor.function, cursor.code, cursor.base)
        return try withSelfInScope(function, code, base: base, on: stack) {
            try constructOrCall(call, &cursor, stack)
        }
    }

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
}
