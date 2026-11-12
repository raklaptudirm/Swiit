import Foundation

extension Interpreter {
    // MARK: Declaring

    // swiftlint:disable function_body_length - a long walk over every case; splitting it is item 17 of Docs/agenda.md
    /// `natives`: Swift bodies for the methods the prelude declares without
    /// one, by `Type.method`.
    func declare(_ decl: StructDecl, natives: [String: FunctionBody] = [:]) throws {
        var computed: [String: Function] = [:]
        for property in decl.properties {
            guard let getter = property.getter else { continue }
            computed[property.name] = Function(
                name: property.name,
                parameters: [],
                returnType: property.type,
                body: .swiit(getter),
                captured: captureScopes(property.getterNames)
            )
        }
        var methods: [String: [Function]] = [:]
        for method in decl.methods {
            methods[method.name, default: []]
                .append(
                    Function(
                        name: method.name,
                        parameters: method.parameters,
                        returnType: method.returnType,
                        body: natives["\(decl.name).\(method.name)"] ?? .swiit(method.body),
                        captured: captureScopes(method.names),
                        documentation: method.documentation,
                        attributes: method.attributes,
                        isMutating: method.isMutating,
                        isThrowing: method.isThrowing
                    )
                )
        }
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
        // As in Swift: every stored property, except a `let` that already
        // has its value, in order; one with a default may be left out.
        let memberwise = Function(
            name: decl.name,
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
        var staticComputed: [String: Function] = [:]
        var staticSetters: [String: Function] = [:]
        for property in decl.staticProperties {
            guard let getter = property.getter else { continue }
            staticComputed[property.name] = Function(
                name: property.name,
                parameters: [],
                returnType: property.type,
                body: .swiit(getter),
                captured: captureScopes(property.getterNames)
            )
            if let setter = property.setter {
                staticSetters[property.name] = Function(
                    name: property.name,
                    parameters: [Parameter(name: property.setterName, type: property.type ?? .any)],
                    returnType: nil,
                    body: .swiit(setter),
                    captured: captureScopes(property.setterNames)
                )
            }
        }
        var staticMethods: [String: [Function]] = [:]
        for method in decl.staticMethods {
            staticMethods[method.name, default: []]
                .append(
                    Function(
                        name: method.name,
                        parameters: method.parameters,
                        returnType: method.returnType,
                        body: .swiit(method.body),
                        captured: captureScopes(method.names),
                        documentation: method.documentation,
                        attributes: method.attributes,
                        isThrowing: method.isThrowing
                    )
                )
        }
        let type = StructType(
            name: decl.name,
            stored: stored,
            computed: computed,
            methods: methods.mapValues { OverloadSet(name: $0[0].name!, candidates: $0) },
            initializers: initializers.isEmpty
                ? nil : OverloadSet(name: "\(decl.name).init", candidates: initializers),
            memberwise: memberwise,
            conformances: decl.conformances,
            staticProperties: decl.staticProperties,
            staticComputed: staticComputed,
            staticMethods: staticMethods.mapValues {
                OverloadSet(name: $0[0].name!, candidates: $0)
            }
        )
        type.staticSetters = staticSetters
        type.isDynamicMemberLookup = decl.isDynamicMemberLookup
        for declared in decl.subscripts {
            type.subscriptGetters.append(
                Function(
                    name: "subscript",
                    parameters: declared.parameters,
                    returnType: declared.returnType,
                    body: .swiit(declared.getter),
                    captured: captureScopes(declared.getterNames)
                )
            )
            type.subscriptSetters.append(
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
        for property in decl.properties {
            if let setter = property.setter {
                type.setters[property.name] = Function(
                    name: property.name,
                    parameters: [Parameter(name: property.setterName, type: property.type ?? .any)],
                    returnType: nil,
                    body: .swiit(setter),
                    captured: captureScopes(property.setterNames),
                    isMutating: true
                )
            }
            if property.willSet != nil || property.didSet != nil {
                func observer(
                    _ body: Program?,
                    _ parameter: String,
                    _ names: NamesUsed
                ) -> Function? {
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
        declaredTypes[type.id] = type
        scopes[scopes.count - 1].bindings[decl.name] = Binding(value: .object(type), mutable: false)
        // Bound first, so a static value can be made of the type itself.
        for property in decl.staticProperties where property.getter == nil {
            guard let expr = property.defaultValue else { continue }
            var value = try evaluate(expr, expecting: property.type)
            if let expected = property.type {
                guard let conforming = conform(value, to: expected) else {
                    throw RuntimeError(
                        "\(decl.name).\(property.name) must be \(expected), not \(value.typeName)"
                    )
                }
                value = conforming
            }
            type.statics[property.name] = StructType.StaticValue(value, mutable: property.mutable)
        }
    }
    // swiftlint:enable function_body_length

    func structType(named name: String) -> StructType? {
        guard case .object(let type as StructType)? = lookup(name)?.value.storage else {
            return nil
        }
        return type
    }

    /// The declaration of a struct value's type: the one its ID names for a type a program
    /// declared, so a value of a type since redeclared keeps its own; for a value of a Swift type,
    /// the struct its name means in scope, if a program declared one.
    func structType(of record: Value.Record) -> StructType? {
        guard let id = record.typeID else { return nil }
        if case .declared = id.kind { return declaredTypes[id] as? StructType }
        return structType(named: id.name)
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
        var chosenInitializers = type.initializers
        var overload = overload
        if let added = typeExtensions[type.name]?.initializers {
            let ownTakes: Bool
            if let own = type.initializers {
                ownTakes =
                    (try? resolve(narrowed(own, overload)) { try self.bind(values, to: $0) }) != nil
            } else {
                ownTakes = (try? bind(values, to: type.memberwise)) != nil
            }
            if !ownTakes { chosenInitializers = added; overload = nil }
        }
        guard let initializers = chosenInitializers else {
            let bound = try bind(values, to: type.memberwise).bindings
            var record = Value.Record(typeID: type.id)
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
        var start = Value.Record(typeID: type.id)
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
        var record = Value.Record(typeID: type.id)
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
