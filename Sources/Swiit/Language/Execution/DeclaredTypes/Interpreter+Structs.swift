import Foundation

extension Interpreter {
    // MARK: Declaring

    /// `natives`: Swift bodies for the methods the prelude declares without
    /// one, by `Type.method`.
    func declare(_ decl: StructDecl, natives: [String: FunctionBody] = [:]) throws {
        let initializers = decl.initializers.map { initializer in
            Function(
                name: "\(decl.name).init",
                parameters: initializer.parameters,
                returnType: nil,
                body: .swiit(initializer.body),
                captured: captureScopes(initializer.names),
                documentation: initializer.documentation,
                isMutating: true,
                isThrowing: initializer.isThrowing,
                isFailable: initializer.isFailable
            )
        }
        let stored = decl.properties.filter { $0.getter == nil }
        let statics = staticFunctions(of: decl.staticProperties)
        let methods = overloads(of: decl.methods) { method in
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
            staticMethods: overloads(of: decl.staticMethods, isStatic: true) { .swiit($0.body) }
        )
        type.members.staticSetters = statics.setters
        type.isDynamicMemberLookup = decl.isDynamicMemberLookup
        declareSubscripts(decl.subscripts, in: type)
        declareSettersAndObservers(decl.properties, in: type)

        declaredTypes[type.typeRef] = type
        scopes[scopes.count - 1].bindings[decl.name] = Binding(value: .object(type), mutable: false)

        // Bound first, so a static value can be made of the type itself.
        try evaluateStaticValues(decl.staticProperties, in: type, named: decl.name)
    }

    /// The getter of each computed property, by name.
    private func computedProperties(of properties: [PropertyDecl]) -> [String: Function] {
        var computed: [String: Function] = [:]
        for property in properties {
            guard let getter = property.getter else { continue }
            computed[property.name] = Function(
                name: property.name,
                parameters: [],
                returnType: property.type,
                body: .swiit(getter),
                captured: captureScopes(property.getterNames)
            )
        }
        return computed
    }

    /// The methods of a declaration, grouped by name into overloads. Static ones are not
    /// mutating.
    private func overloads(
        of methods: [FunctionDecl],
        isStatic: Bool = false,
        body: (FunctionDecl) -> FunctionBody
    ) -> [String: OverloadSet] {
        var grouped: [String: [Function]] = [:]
        for method in methods {
            grouped[method.name, default: []]
                .append(
                    Function(
                        name: method.name,
                        parameters: method.parameters,
                        returnType: method.returnType,
                        body: body(method),
                        captured: captureScopes(method.names),
                        documentation: method.documentation,
                        attributes: method.attributes,
                        isMutating: !isStatic && method.isMutating,
                        isThrowing: method.isThrowing
                    )
                )
        }
        return grouped.mapValues { OverloadSet(name: $0[0].name!, candidates: $0) }
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

    /// The getters and setters of the computed static properties, by name.
    private func staticFunctions(
        of properties: [PropertyDecl]
    ) -> (getters: [String: Function], setters: [String: Function]) {
        var getters: [String: Function] = [:]
        var setters: [String: Function] = [:]
        for property in properties {
            guard let getter = property.getter else { continue }
            getters[property.name] = Function(
                name: property.name,
                parameters: [],
                returnType: property.type,
                body: .swiit(getter),
                captured: captureScopes(property.getterNames)
            )
            if let setter = property.setter {
                setters[property.name] = Function(
                    name: property.name,
                    parameters: [Parameter(name: property.setterName, type: property.type ?? .any)],
                    returnType: nil,
                    body: .swiit(setter),
                    captured: captureScopes(property.setterNames)
                )
            }
        }
        return (getters, setters)
    }

    private func declareSubscripts(_ subscripts: [SubscriptDecl], in type: StructType) {
        for declared in subscripts {
            type.members.subscriptGetters.append(
                Function(
                    name: "subscript",
                    parameters: declared.parameters,
                    returnType: declared.returnType,
                    body: .swiit(declared.getter),
                    captured: captureScopes(declared.getterNames)
                )
            )
            type.members.subscriptSetters.append(
                declared.setter.map { setter in
                    Function(
                        name: "subscript",
                        parameters: declared.parameters + [
                            Parameter(name: declared.setterName, type: declared.returnType)
                        ],
                        returnType: nil,
                        body: .swiit(setter),
                        captured: captureScopes(declared.setterNames),
                        isMutating: true
                    )
                }
            )
        }
    }

    private func declareSettersAndObservers(_ properties: [PropertyDecl], in type: StructType) {
        for property in properties {
            if let setter = property.setter {
                type.members.setters[property.name] = Function(
                    name: property.name,
                    parameters: [Parameter(name: property.setterName, type: property.type ?? .any)],
                    returnType: nil,
                    body: .swiit(setter),
                    captured: captureScopes(property.setterNames),
                    isMutating: true
                )
            }

            guard property.willSet != nil || property.didSet != nil else { continue }
            func observer(_ body: Program?, _ parameter: String, _ names: NamesUsed) -> Function? {
                body.map { body in
                    Function(
                        name: property.name,
                        parameters: [Parameter(name: parameter, type: property.type ?? .any)],
                        returnType: nil,
                        body: .swiit(body),
                        captured: captureScopes(names),
                        isMutating: true
                    )
                }
            }
            type.observers[property.name] = (
                observer(property.willSet, property.willSetName, property.willSetNames),
                observer(property.didSet, property.didSetName, property.didSetNames)
            )
        }
    }

    private func evaluateStaticValues(
        _ properties: [PropertyDecl],
        in type: StructType,
        named name: String
    ) throws {
        for property in properties where property.getter == nil {
            guard let expr = property.defaultValue else { continue }
            var value = try evaluate(expr, expecting: property.type)
            if let expected = property.type {
                guard let conforming = conform(value, to: expected) else {
                    throw RuntimeError(
                        "\(name).\(property.name) must be \(expected), not \(value.typeName)"
                    )
                }
                value = conforming
            }
            type.members.statics[property.name] = StructType.StaticValue(
                value,
                mutable: property.mutable
            )
        }
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
