import Foundation

extension Interpreter {
    /// `enum Name: Raw { … }`: builds the type, checking raw values, and binds
    /// its name.
    func declare(_ decl: EnumDecl) throws {
        var cases: [Value.EnumCase.Enumeration.Case] = []
        var payloadTypes: [String: [TypeExpression]] = [:]
        var nextInt = 0
        var rawSeen: Set<Value> = []
        for enumCase in decl.cases {
            var raw: Value?
            if let rawType = decl.rawType {
                guard enumCase.associated.isEmpty else {
                    throw RuntimeError(
                        "\(decl.name).\(enumCase.name): an enum with raw values can't have associated values"
                    )
                }
                if let expr = enumCase.rawValue {
                    let value = try evaluate(expr)
                    guard let conforming = value.conforming(to: rawType) else {
                        throw RuntimeError(
                            "\(decl.name).\(enumCase.name)'s raw value must be \(rawType), not \(value.typeName)"
                        )
                    }
                    raw = conforming
                } else {
                    switch rawType {
                    case .int: raw = .int(nextInt)
                    case .string: raw = .string(enumCase.name)
                    default: throw RuntimeError("\(decl.name).\(enumCase.name) needs a raw value")
                    }
                }
                if case .int(let n)? = raw?.storage { nextInt = n + 1 }
                guard rawSeen.insert(raw!).inserted else {
                    throw RuntimeError(
                        "\(decl.name).\(enumCase.name): raw value \(raw!) is used twice"
                    )
                }
            } else if enumCase.rawValue != nil {
                throw RuntimeError(
                    "\(decl.name).\(enumCase.name): only an enum with a raw type, like `enum \(decl.name): Int`, has raw values"
                )
            }
            cases.append(
                Value.EnumCase.Enumeration.Case(
                    name: enumCase.name,
                    rawValue: raw,
                    labels: enumCase.associated.map(\.label)
                )
            )
            payloadTypes[enumCase.name] = enumCase.associated.map(\.type)
        }
        let type = Value.EnumCase.Enumeration(
            declaring: decl.name,
            cases: cases,
            typeRef: takeReservedRef(decl.name)
        )
        declaredTypes[type.typeRef] = type
        type.payloadTypes = payloadTypes
        type.conformances = decl.conformances
        type.typeParameters = decl.typeParameters
        scopes[scopes.count - 1].bindings[decl.name] = Binding(value: .object(type), mutable: false)
        try declareMembers(of: decl, on: type)
    }

    /// An enum's computed properties and methods, and its static ones.
    private func declareMembers(of decl: EnumDecl, on type: Value.EnumCase.Enumeration) throws {
        let enumType = EnumType(type)
        enumTypes[ObjectIdentifier(type)] = enumType
        var source = StructDecl(
            name: decl.name,
            properties: decl.properties,
            methods: decl.methods,
            initializers: decl.initializers
        )
        source.staticProperties = decl.staticProperties
        source.staticMethods = decl.staticMethods
        try fill(enumType.members, of: decl.name, from: source)
    }

    /// What an enum a program declared adds to its cases: nil for a host's enum, which adds nothing.
    func enumMembers(of type: Value.EnumCase.Enumeration) -> TypeMembers? {
        enumTypes[ObjectIdentifier(type)]?.members
    }

    /// `Direction(code: "N")`: through an `init` the enum declares, which sets `self` to a case.
    func constructEnum(
        _ type: Value.EnumCase.Enumeration,
        _ initializers: OverloadSet,
        _ arguments: [Argument],
        overload: Int?
    ) throws -> Value {
        let values = try arguments.map { argument -> Argument in
            if case .caseLiteral = argument.value { return argument }
            return Argument(label: argument.label, value: .literal(try evaluate(argument.value)))
        }
        let (initializer, bindings) = try resolve(narrowed(initializers, overload)) {
            try self.bind(values, to: $0)
        }
        let receiver = Receiver(.nothing, mutable: true, initializing: true)
        task.failedInit = false
        _ = try invoke(initializer, with: bindings, receiver: receiver)
        if task.failedInit {
            task.failedInit = false
            return .nothing
        }
        guard case .enumValue = receiver.value.storage else {
            throw RuntimeError("\(type.name).init must set self to a case")
        }
        return receiver.value
    }

    /// A computed property of an enum's case, or a method as a function value; nil if there isn't
    /// one.
    func enumMember(_ name: String, of value: Value.EnumCase) throws -> Value? {
        guard let members = enumMembers(of: value.type) else { return nil }
        if let getter = members.computed[name] {
            return try invoke(
                getter,
                with: [:],
                receiver: Receiver(.enumValue(value), mutable: false)
            )
        }
        guard let methods = members.methods[name] else { return nil }
        let bound = methods.candidates.map { method in
            Function(
                name: method.name,
                parameters: method.parameters,
                returnType: method.returnType,
                body: .native { interpreter, _, values in
                    guard !method.isMutating else {
                        throw RuntimeError(
                            "mutating method '\(name)' must be called on a variable, as in value.\(name)(…)"
                        )
                    }
                    return try interpreter.invoke(
                        method,
                        with: Arguments(method.parameters, values),
                        receiver: Receiver(.enumValue(value), mutable: false)
                    )
                },
                documentation: method.documentation,
                attributes: method.attributes,
                isMutating: method.isMutating
            )
        }
        return .function(OverloadSet(name: name, candidates: bound))
    }

    /// `Level.default`, `Level.make`: an enum's static member; nil if it has none by that name.
    func enumStaticMember(_ name: String, of type: Value.EnumCase.Enumeration) throws -> Value? {
        guard let members = enumMembers(of: type) else { return nil }
        if let getter = members.staticComputed[name] { return try invoke(getter, with: [:]) }
        if let slot = members.statics[name] { return slot.value }
        return members.staticMethods[name].map(Value.function)
    }

    /// The enum a type names, looking through optionals.
    func enumType(for type: TypeExpression?) -> Value.EnumCase.Enumeration? {
        guard let type else { return nil }
        if let wrapped = type.optionalWrapped { return enumType(for: wrapped) }
        return type.swiftType.flatMap { enumType(named: $0.name) }
    }

    func enumType(named name: String) -> Value.EnumCase.Enumeration? {
        guard case .object(let type as Value.EnumCase.Enumeration)? = lookup(name)?.value.storage
        else {
            return nil
        }
        return type
    }

    /// `Kind.file`, `.failed(code: 2)` or `Kind.failed(code: 2)` for `type`:
    /// checks the case exists and its associated values' labels and types.
    func makeCase(
        _ type: Value.EnumCase.Enumeration,
        _ name: String,
        _ arguments: [Argument]?
    ) throws -> Value {
        guard let definition = type.case(named: name) else {
            throw RuntimeError("\(type.name) has no case '\(name)'")
        }
        let written = "\(type.name).\(name)"
        guard let arguments else {
            guard definition.labels.isEmpty else {
                let labels = definition.labels.map { ($0 ?? "_") + ":" }.joined()
                throw RuntimeError("\(written) needs its associated values: \(written)(\(labels))")
            }
            return .enumValue(Value.EnumCase(type: type, name: name))
        }
        guard !definition.labels.isEmpty else {
            throw RuntimeError("\(written) has no associated values")
        }
        guard arguments.count == definition.labels.count else {
            throw RuntimeError(
                "\(written) has \(definition.labels.count) associated values, not \(arguments.count)"
            )
        }
        let types = type.payloadTypes[name] ?? []
        var values: [Value] = []
        for (index, argument) in arguments.enumerated() {
            guard argument.label == definition.labels[index] else {
                let expected = definition.labels[index].map { "'\($0):'" } ?? "no label"
                throw RuntimeError("\(written): value #\(index + 1) needs \(expected)")
            }
            let type = index < types.count ? types[index] : .any
            let value = try evaluate(argument.value, expecting: type)
            guard let conforming = conform(value, to: type) else {
                throw RuntimeError(
                    "\(written): value #\(index + 1) must be \(type), not \(value.typeName)"
                )
            }
            values.append(conforming)
        }
        return .enumValue(Value.EnumCase(type: type, name: name, values: values))
    }
}

extension Interpreter {
    /// A case of an enum the prelude or the standard library module
    /// declares: `FileType.directory`.
    func declaredCase(_ type: String, _ name: String) -> Value {
        .enumValue(Value.EnumCase(type: enumType(named: type)!, name: name))
    }
}
