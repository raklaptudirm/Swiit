import Foundation

extension Interpreter {
    // MARK: Declaring

    /// `natives`: Swift bodies for the methods the prelude declares without
    /// one, by `Type.method`.
    func declare(_ decl: StructDecl, natives: [String: FunctionBody] = [:]) throws {
        let initializers = initializerFunctions(of: decl.initializers, in: decl.name)
        let stored = decl.properties.filter { $0.getter == nil }
        let statics = staticFunctions(of: decl.staticProperties)
        let methods = overloads(of: decl.methods, honorsMutating: true) { method in
            natives["\(decl.name).\(method.name)"] ?? .swiit(method.body)
        }

        let type = StructType(
            name: decl.name,
            stored: stored,
            computed: computedProperties(of: decl.properties),
            methods: methods,
            initializers: initializers.isEmpty
                ? nil : OverloadSet(name: "\(decl.name).init", candidates: initializers),
            memberwise: memberwiseInitializer(of: decl.name, stored: stored),
            conformances: decl.conformances,
            staticProperties: decl.staticProperties,
            staticComputed: statics.getters,
            staticMethods: overloads(of: decl.staticMethods) { .swiit($0.body) },
            typeRef: takeReservedRef(decl.name)
        )
        type.members.staticSetters = statics.setters
        type.isDynamicMemberLookup = decl.isDynamicMemberLookup
        declareSubscripts(decl.subscripts, in: type.members)
        type.observers = declareSettersAndObservers(decl.properties, in: type.members)

        declaredTypes[type.typeRef] = type
        scopes[scopes.count - 1].bindings[decl.name] = Binding(value: .object(type), mutable: false)

        // Bound first, so a static value can be made of the type itself.
        try evaluateStaticValues(decl.staticProperties, in: type.members, named: decl.name)
    }

    /// As in Swift: every stored property, except a `let` that already has its value, in order;
    /// one with a default may be left out.
    private func memberwiseInitializer(of name: String, stored: [PropertyDecl]) -> Function {
        Function(
            name: name,
            parameters: stored.filter { $0.mutable || $0.defaultValue == nil }
                .map { property in
                    Parameter(
                        label: property.name,
                        name: property.name,
                        type: property.type ?? .any,
                        defaultValue: property.defaultValue
                    )
                },
            returnType: nil,
            body: .native { _, _ in .nothing },
            captured: captureScopes(NamesUsed())
        )
    }

    func structType(named name: String) -> StructType? {
        guard case .object(let type as StructType)? = lookup(name)?.value.storage else {
            return nil
        }
        return type
    }

    /// The declaration of a struct value's type: the one its reference names for a type a program
    /// declared, so a value of a type since redeclared keeps its own; for a value of a Swift type,
    /// the struct its name means in scope, if a program declared one.
    func structType(of record: Value.Record) -> StructType? {
        guard let typeRef = record.typeRef else { return nil }
        if case .declared = typeRef.kind { return declaredTypes[typeRef] as? StructType }
        return structType(named: typeRef.name)
    }

    // MARK: Making values

    /// `Point(x: 1, y: 2)`: through an `init` the struct declares, or the
    /// memberwise one.
    func construct(
        _ type: StructType,
        _ arguments: [Argument],
        overload: Int? = nil
    ) throws -> Value {
        let values = try arguments.map { argument -> Argument in
            if case .caseLiteral = argument.value { return argument }
            return Argument(label: argument.label, value: .literal(try evaluate(argument.value)))
        }
        // What an extension adds is tried when the type's own don't take the arguments.
        var chosenInitializers = type.members.initializers
        var overload = overload
        if let added = typeExtensions[type.name]?.initializers {
            let ownTakes: Bool
            if let own = type.members.initializers {
                ownTakes =
                    (try? resolve(narrowed(own, overload)) { try self.bind(values, to: $0) }) != nil
            } else {
                ownTakes = (try? bind(values, to: type.memberwise)) != nil
            }
            if !ownTakes { chosenInitializers = added; overload = nil }
        }
        guard let initializers = chosenInitializers else {
            let bound = try bind(values, to: type.memberwise).bindings
            var record = Value.Record(typeRef: type.typeRef)
            record.reserveCapacity(type.stored.count)
            for property in type.stored {
                if let value = bound[property.name] {
                    record[property.name] = value
                } else if let defaultValue = property.defaultValue {
                    record[property.name] = try storedValue(defaultValue, for: property, of: type)
                }
            }
            return Value(record: record)
        }

        let (initializer, bindings) = try resolve(narrowed(initializers, overload)) {
            try self.bind(values, to: $0)
        }
        // Defaults first, then whatever the initializer sets.
        var start = Value.Record(typeRef: type.typeRef)
        start.reserveCapacity(type.stored.count)
        for property in type.stored {
            if let defaultValue = property.defaultValue {
                start[property.name] = try storedValue(defaultValue, for: property, of: type)
            }
        }
        let receiver = Receiver(Value(record: start), mutable: true, initializing: true)
        task.failedInit = false
        _ = try invoke(initializer, with: bindings, receiver: receiver)
        if task.failedInit {
            task.failedInit = false
            return .nothing
        }
        guard let made = receiver.value.record else {
            throw RuntimeError("\(type.name).init must leave self a \(type.name)")
        }
        // In declaration order, whatever order the initializer set them in.
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

    private func storedValue(
        _ expr: Expr,
        for property: PropertyDecl,
        of type: StructType
    ) throws -> Value {
        let value = try evaluate(expr, expecting: property.type)
        return try checked(value, as: property, of: type)
    }

    func checked(_ value: Value, as property: PropertyDecl, of type: StructType) throws -> Value {
        guard let expected = property.type else { return value }
        guard let conforming = conform(value, to: expected) else {
            throw RuntimeError(
                "\(type.name).\(property.name) must be \(expected), not \(value.typeName)"
            )
        }
        return conforming
    }
}
