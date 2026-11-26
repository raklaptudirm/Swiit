import Foundation

// What the loop does as a method frame begins and ends: its `self`, the scopes it runs in, and what
// returning undoes.

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
        if let owner = target.function.owner { task.owners.append(owner) }
        task.callDepth += 1
        let changes = cell != nil && target.function.isMutating && !target.isClass
        return MethodExit(
            selfCell: cell,
            popsOwner: target.function.owner != nil,
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
}
