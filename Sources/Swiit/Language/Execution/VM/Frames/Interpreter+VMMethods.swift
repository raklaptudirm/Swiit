import Foundation

// Calling a method from the loop: finding it for the receiver, and what its frame does with `self` as it
// begins and ends.

/// What a method's or an initializer's frame begins with: where it is in the stack, where the caller
/// resumes, how `self` is held, and what returning gives.
struct MethodFrame {
    let function: Function
    let code: Code
    /// The register, counted from the stack's start, of the first argument, which is the frame's first.
    let argumentBase: Int
    /// The instruction the caller resumes at.
    let resumeAt: Int
    /// The register, counted from the stack's start, the result goes to.
    let destination: Int
    /// The caller's scopes, kept to be put back, when the call runs in scopes of its own.
    let savedScopes: [Scope]?
    let held: HeldSelf
    let ending: MethodExit.Ending
}

/// How a frame holds `self`: what the register of `self` starts with, and the cell `self` is held in,
/// through which what the body changes is read back.
struct HeldSelf {
    /// What the register of `self` starts with; nil for a body that has none.
    let register: Value?
    let cell: Binding.Cell?

    /// The receiver of a method, as its body holds it.
    static func receiver(_ receiver: Value, as storage: Code.SelfStorage) -> HeldSelf {
        switch storage {
        case .none:
            return HeldSelf(register: nil, cell: nil)
        case .value:
            return HeldSelf(register: receiver, cell: nil)
        case .cell, .initializing:
            let cell = Binding.Cell(receiver)
            return HeldSelf(register: .object(cell), cell: cell)
        }
    }

    /// The value an initializer makes: held in a cell whether or not the body names `self`, because
    /// the value is read back from it as the initializer returns.
    static func made(_ start: Value, as storage: Code.SelfStorage) -> HeldSelf {
        let cell = Binding.Cell(start)
        return HeldSelf(register: storage.register == nil ? nil : .object(cell), cell: cell)
    }
}

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
        let holdsCell = if case .cell = target.code.selfStorage { true } else { false }
        guard !site.isSuper, !site.isGetter, target.mapping == nil,
            !ownScope, site.sharesScopes, !extended,
            !target.code.usesSuper,
            changes
                ? !site.receiverIsSelf && holdsCell
                : !target.function.isMutating && !target.code.selfStorage.holdsCell,
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
        let back = writeBack(
            of: target,
            storeAt: cursor.base + Int(operands.receiver),
            storeIn: storeIn
        )
        let held: HeldSelf
        if ownScope {
            held = bindSelfInScope(
                receiverValue,
                of: target.function,
                mutable: target.isClass || target.function.isMutating,
                special: nil
            )
        } else {
            held = .receiver(receiverValue, as: target.code.selfStorage)
            if !site.sharesScopes || extended {
                setScopes(of: target.function, from: cursor.function, task)
            }
        }
        let ending = MethodExit.Ending.method(held.cell == nil ? .none : back)
        // The cell of `self` holds the struct alone while the method changes it, so that it is changed
        // where it is; it goes back where it came from as the method returns or fails.
        if held.cell != nil, back.changesReceiver {
            stack.base[cursor.base + Int(operands.receiver)] = .nothing
            back.store(.nothing, on: stack)
        }
        enterMethodFrame(
            MethodFrame(
                function: target.function,
                code: target.code,
                argumentBase: argumentBase,
                resumeAt: cursor.pc + Int(operands.offset),
                destination: cursor.base + Int(operands.dst),
                savedScopes: saved,
                held: held,
                ending: ending
            ),
            &cursor,
            stack
        )
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
    /// What returning from a method the loop called undoes, and, for an initializer, the value it gives:
    /// the class pushed for `super` is popped, and a struct the method changed goes back where the
    /// receiver came from.
    func finishMethod(_ exit: MethodExit, on stack: VMStack) throws -> Value? {
        if exit.popsOwner { task.owners.removeLast() }
        switch exit.ending {
        case .method(let back):
            if let cell = exit.selfCell { back.store(cell.value, on: stack) }
            return nil
        case .initializer(.structValue(let type)):
            guard let cell = exit.selfCell else { return nil }
            return try madeStruct(of: type, from: cell)
        case .initializer(.classInstance(let instance, let initializer, let saved)):
            defer { task.calledSuperInit = saved }
            try completeInitialization(of: instance, by: initializer)
            try checkAllSet(instance)
            return .object(instance)
        }
    }

    /// The struct an initializer of `type` left in the cell of `self`: the fields set in the order the
    /// type declares them are the value as they are, and the rest are put in that order.
    private func madeStruct(of type: StructType, from cell: Binding.Cell) throws -> Value {
        guard let made = cell.value.record else {
            throw RuntimeError("\(type.name).init must leave self a \(type.name)")
        }
        if made.hasKeys(type.storedNames) { return Value(record: made) }

        var record = Value.Record(typeRef: type.typeRef, capacity: type.stored.count)
        for property in type.stored {
            guard let value = made[property.name] else {
                throw RuntimeError("\(type.name).init must set '\(property.name)'")
            }
            record.appendDistinct(property.name, value)
        }
        return Value(record: record)
    }

    /// An error left a method's frame: what it pushed is undone, and what a method changed of its
    /// receiver before it failed is kept, as Swift keeps it. An initializer makes nothing.
    func abandonMethod(_ exit: MethodExit, on stack: VMStack) {
        if exit.popsOwner { task.owners.removeLast() }
        switch exit.ending {
        case .method(let back):
            if let cell = exit.selfCell { back.store(cell.value, on: stack) }
        case .initializer(.classInstance(_, _, let saved)):
            task.calledSuperInit = saved
        case .initializer(.structValue):
            break
        }
    }

    /// Where what a method changed of a struct goes back to: the cell of the global or of the caller's
    /// `self` the receiver came from, or the register it was in. Nothing for a method that does not
    /// change it, or a class's.
    func writeBack(
        of target: MethodTarget,
        storeAt: Int,
        storeIn: Binding.Cell?
    ) -> MethodExit.WriteBack {
        guard target.function.isMutating, !target.isClass else { return .none }
        return storeIn.map(MethodExit.WriteBack.cell) ?? .register(storeAt)
    }

    /// In the frame of a method, the scope that binds `self` by name, which what looks names up
    /// (a tree node, a closure) finds it in: made the first time, and kept until the method returns.
    @inline(__always)
    func ensureSelfScope(_ function: Function, _ code: Code, base: Int, on stack: VMStack) {
        if code.selfRegister != nil { makeSelfScope(function, code, base: base, on: stack) }
    }

    func makeSelfScope(_ function: Function, _ code: Code, base: Int, on stack: VMStack) {
        guard let register = code.selfRegister, task.scopes.count == function.captured.count
        else { return }
        let held = stack.base[base + Int(register)]
        var binding: Binding
        if !code.selfStorage.holdsCell {
            // The value of `self` was put in the register; a cell of its own is made for the scope.
            var mutable = false
            if case .object(is ClassInstance) = held.storage { mutable = true }
            binding = Binding(value: held, mutable: mutable)
        } else {
            guard case .object(let object) = held.storage, let cell = object as? Binding.Cell else {
                return
            }
            let initializing = if case .initializing = code.selfStorage { true } else { false }
            var mutable = function.isMutating || initializing
            if case .object(is ClassInstance) = cell.value.storage { mutable = true }
            binding = Binding(cell: cell, mutable: mutable)
            if initializing { binding.special = .initializing }
        }
        var table = BindingTable(capacity: 1)
        table["self"] = binding
        task.scopes = function.captured + [Scope(table: table)]
    }

}

extension Interpreter {
    /// Pushes the frame of a method or an initializer and moves the cursor to its first instruction:
    /// what every call of one the loop makes does, whatever made the receiver.
    @inline(__always)
    func enterMethodFrame(
        _ frame: consuming MethodFrame,
        _ cursor: inout VMCursor,
        _ stack: VMStack
    ) {
        // The class is pushed for `super`, which only a body that names it asks for.
        let owner = superclassOwner(of: frame.function, frame.code)
        if let owner { task.owners.append(owner) }
        task.callDepth += 1

        stack.push(
            VMCaller(
                code: cursor.code,
                function: cursor.function,
                callee: frame.function,
                pc: frame.resumeAt,
                base: cursor.base,
                statement: cursor.statement,
                destination: frame.destination,
                isMethod: true
            ),
            scopes: frame.savedScopes
        )
        stack.methodExits.append(
            MethodExit(selfCell: frame.held.cell, popsOwner: owner != nil, ending: frame.ending)
        )

        stack.ensure(frame.argumentBase + frame.code.frameSize)
        stack.top = frame.argumentBase + frame.code.frameSize
        cursor = VMCursor(
            function: frame.function,
            code: frame.code,
            base: frame.argumentBase,
            pc: 0,
            statement: -1
        )
        if let register = frame.code.selfRegister, let value = frame.held.register {
            stack.base[frame.argumentBase + Int(register)] = value
        }
    }

    /// The class a call of `function` pushes for `super`: its own, for a body that names `super`.
    func superclassOwner(of function: Function, _ code: Code) -> ClassType? {
        code.usesSuper && code.hasOwner ? function.owner : nil
    }

    /// `self` bound by name in a scope of the call's own, after the scopes `function` captured: for a
    /// body that looks names up and has no register of `self`.
    func bindSelfInScope(
        _ receiver: Value,
        of function: Function,
        mutable: Bool,
        special: Binding.Special?
    ) -> HeldSelf {
        let binding = Binding(value: receiver, mutable: mutable, special: special)
        // A scope made for a call is seen by nothing made before it, so the names are not changed.
        var table = BindingTable(capacity: 1)
        table["self"] = binding
        var inside = function.captured
        inside.append(Scope(table: table))
        task.scopes = inside
        return HeldSelf(register: nil, cell: binding.cell)
    }
}
