import Foundation

// Reading and writing through subscripts.

extension Interpreter {
    /// `grid[1, 2]`: a struct's subscript read, with `self` the value.
    func readSubscript(_ instance: ClassInstance, _ arguments: [Argument]) throws -> Value {
        guard let owner = instance.type.subscriptOwner else {
            throw RuntimeError("\(instance.type.name) has no subscript")
        }
        let values = try arguments.map {
            Argument(label: $0.label, value: .literal(try evaluate($0.value)))
        }
        let (getter, bindings) = try resolve(
            OverloadSet(name: "subscript", candidates: owner.subscriptGetters)
        ) {
            try self.bind(values, to: $0)
        }
        return try invoke(
            getter,
            with: bindings,
            receiver: Receiver(.object(instance), mutable: true)
        )
    }

    func writeSubscript(
        _ instance: ClassInstance,
        _ arguments: [Argument],
        _ rest: ArraySlice<Assignment.Step>,
        _ change: (Value, TypeAnnotation?) throws -> Value
    ) throws -> Value {
        guard let owner = instance.type.subscriptOwner else {
            throw RuntimeError("\(instance.type.name) has no subscript")
        }
        let values = try arguments.map {
            Argument(label: $0.label, value: .literal(try evaluate($0.value)))
        }
        let (getter, bindings) = try resolve(
            OverloadSet(name: "subscript", candidates: owner.subscriptGetters)
        ) {
            try self.bind(values, to: $0)
        }
        guard let position = owner.subscriptGetters.firstIndex(where: { $0 === getter }),
            let setter = owner.subscriptSetters[position]
        else {
            throw RuntimeError(
                "cannot assign through \(instance.type.name)'s subscript: it's get-only"
            )
        }
        let receiver = Receiver(.object(instance), mutable: true)
        let current = try invoke(getter, with: bindings, receiver: receiver)
        let updatedValue =
            try rest.isEmpty
            ? change(current, getter.returnType)
            : updated(current, rest, type: getter.returnType, change)
        var all = bindings
        all[setter.parameters[setter.parameters.count - 1].name] = updatedValue
        _ = try invoke(setter, with: all, receiver: receiver)
        return .object(instance)
    }

    func readSubscript(
        _ record: Value.Record,
        _ type: StructType,
        _ arguments: [Argument]
    ) throws -> Value {
        let values = try arguments.map {
            Argument(label: $0.label, value: .literal(try evaluate($0.value)))
        }
        let (getter, bindings) = try resolve(
            OverloadSet(name: "subscript", candidates: type.subscriptGetters)
        ) {
            try self.bind(values, to: $0)
        }
        return try invoke(
            getter,
            with: bindings,
            receiver: Receiver(Value(record: record), mutable: false)
        )
    }

    /// `grid[1, 2] = v` (or with `rest`, a change deeper inside it): the value through the
    /// subscript's setter.
    func writeSubscript(
        _ record: Value.Record,
        _ type: StructType,
        _ arguments: [Argument],
        _ rest: ArraySlice<Assignment.Step>,
        _ change: (Value, TypeAnnotation?) throws -> Value
    ) throws -> Value {
        let values = try arguments.map {
            Argument(label: $0.label, value: .literal(try evaluate($0.value)))
        }
        let (getter, bindings) = try resolve(
            OverloadSet(name: "subscript", candidates: type.subscriptGetters)
        ) {
            try self.bind(values, to: $0)
        }
        guard let position = type.subscriptGetters.firstIndex(where: { $0 === getter }),
            let setter = type.subscriptSetters[position]
        else {
            throw RuntimeError("cannot assign through \(type.name)'s subscript: it's get-only")
        }
        let current = try invoke(
            getter,
            with: bindings,
            receiver: Receiver(Value(record: record), mutable: false)
        )
        let updatedValue =
            try rest.isEmpty
            ? change(current, getter.returnType)
            : updated(current, rest, type: getter.returnType, change)
        var all = bindings
        all[setter.parameters[setter.parameters.count - 1].name] = updatedValue
        let receiver = Receiver(Value(record: record), mutable: true)
        _ = try invoke(setter, with: all, receiver: receiver)
        return receiver.value
    }
}

extension Interpreter {
    /// `value[label: 1]` where an extension adds the subscript to a type that is not a struct or
    /// a class: the extension's getter, with `value` as `self`; nil if there is none.
    func extensionSubscript(on target: Value, _ arguments: [Argument]) throws -> Value? {
        guard target.record == nil, let key = typeKey(of: target),
            let getters = typeExtensions[key]?.subscriptGetters, !getters.isEmpty
        else { return nil }
        let values = try arguments.map {
            Argument(label: $0.label, value: .literal(try evaluate($0.value)))
        }
        let (getter, bindings) = try resolve(OverloadSet(name: "subscript", candidates: getters)) {
            try self.bind(values, to: $0)
        }
        return try invoke(getter, with: bindings, receiver: Receiver(target, mutable: false))
    }
}
