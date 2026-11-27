import Foundation

// Reading and setting the stored fields of structs and instances where they are, as the loop does
// itself.

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
}

extension Value {
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
        return site.propertyKind.accepts(value) ? value : conform(value, to: type)
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

extension Value {
    /// The type of the struct this is, if it is one: found without holding the struct.
    var structTypeRef: TypeRef? {
        if case .structure(let structure) = storage { return structure.typeRefIfAny }
        return nil
    }
}

extension Interpreter {
    /// `value.name` when it is a stored field of a struct or of a class's instance, read where it is as
    /// `member(_:of:)` reads it first.
    @inline(__always)
    func storedField(_ name: String, of value: Value) -> Value? {
        switch value.storage {
        case .structure(let structure):
            return structure[name]
        case .object(let object):
            if let instance = object as? ClassInstance, let stored = instance.storage[name] {
                return read(stored)
            }
            return nil
        default:
            return nil
        }
    }
}
