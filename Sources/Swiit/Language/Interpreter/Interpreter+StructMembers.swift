import Foundation

// Reading and calling a struct's members: properties, static members and methods.

extension Interpreter {
    /// A computed property's value, or a method as a function value; nil if
    /// the type has neither by that name.
    func structMember(_ name: String, of record: Value.Record, _ type: StructType) throws -> Value?
    {
        if let getter = type.computed[name] {
            return try invoke(
                getter,
                with: [:],
                receiver: Receiver(Value(record: record), mutable: false)
            )
        }
        guard let methods = type.methods[name] else { return nil }
        // `let f = p.describe`: the method with `p` as `self`.
        let bound = methods.candidates.map { method in
            Function(
                name: method.name,
                parameters: method.parameters,
                returnType: method.returnType,
                body: .native { interpreter, arguments in
                    guard !method.isMutating else {
                        throw RuntimeError(
                            "mutating method '\(name)' must be called on a variable, as in p.\(name)(…)"
                        )
                    }
                    return try interpreter.invoke(
                        method,
                        with: arguments,
                        receiver: Receiver(Value(record: record), mutable: false)
                    )
                },
                documentation: method.documentation,
                attributes: method.attributes,
                isMutating: method.isMutating
            )
        }
        return .function(OverloadSet(name: name, candidates: bound))
    }

    /// `Point.origin`, `Point.count`, or a static method as a function value;
    /// nil if the type has no static member by that name.
    func staticMember(_ name: String, of type: StructType) throws -> Value? {
        if let getter = type.staticComputed[name] { return try invoke(getter, with: [:]) }
        if let slot = type.statics[name] { return slot.value }
        return type.staticMethods[name].map(Value.function)
    }

    /// `Point.make(1)`.
    func callStatic(_ methods: OverloadSet, _ arguments: [Argument]) throws -> Value {
        let values = try arguments.map { argument -> Argument in
            if case .caseLiteral = argument.value { return argument }
            return Argument(label: argument.label, value: .literal(try evaluate(argument.value)))
        }
        let (method, bindings) = try resolve(methods) { try self.bind(values, to: $0) }
        return try invoke(method, with: bindings)
    }

    /// `p.move(by: 1)`. A mutating method changes `p` itself, so `p` must
    /// be a `var` (or a part of one).
    func callMethod(
        _ methods: OverloadSet,
        of base: Value,
        at baseExpr: Expr,
        _ arguments: [Argument]
    ) throws -> Value {
        let values = try arguments.map { argument -> Argument in
            if case .caseLiteral = argument.value { return argument }
            return Argument(label: argument.label, value: .literal(try evaluate(argument.value)))
        }
        let (method, bindings) = try resolve(methods) { try self.bind(values, to: $0) }
        guard method.isMutating else {
            return try invoke(method, with: bindings, receiver: Receiver(base, mutable: false))
        }
        guard let (root, path) = lvalue(baseExpr) else {
            throw RuntimeError(
                "cannot use mutating method '\(methods.name)' on a value that isn't in a variable"
            )
        }
        try checkAssignable(root, what: "use mutating method '\(methods.name)' on")
        let receiver = Receiver(base, mutable: true)
        let result = try invoke(method, with: bindings, receiver: receiver)
        try update(root, path) { _, _ in receiver.value }
        return result
    }
}
