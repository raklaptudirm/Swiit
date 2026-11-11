import SwiftSyntax

// Lowering functions and initializers: their parameters, generics and bodies.

extension Lowering {
    mutating func parameters(_ clause: FunctionParameterClauseSyntax) throws -> [Parameter] {
        let parameters = try lowerParameters(clause)
        try validate(parameters, in: clause)
        return parameters
    }

    /// As in Swift, what follows a variadic needs a label, so it's clear where the variadic ends.
    private func validate(_ parameters: [Parameter], in node: some SyntaxProtocol) throws {
        var seen: Set<String> = []
        for (index, parameter) in parameters.enumerated() {
            if parameter.name != "_" && !seen.insert(parameter.name).inserted {
                throw SyntaxError(
                    "duplicate parameter '\(parameter.name)' (line \(line(of: node)))"
                )
            }
            if parameter.variadic && index + 1 < parameters.count
                && parameters[index + 1].label == nil
            {
                throw SyntaxError(
                    "the parameter after a variadic needs a label (line \(line(of: node)))"
                )
            }
            if parameter.variadic && parameter.defaultValue != nil {
                throw SyntaxError(
                    "a variadic parameter can't have a default value (line \(line(of: node)))"
                )
            }
        }
    }

    private mutating func lowerParameters(
        _ clause: FunctionParameterClauseSyntax
    ) throws -> [Parameter] {
        try clause.parameters.map { parameter in
            var resultBuilder: String?
            // `inout Int`: a specifier before the type.
            let isInout =
                parameter.type.as(AttributedTypeSyntax.self)?.specifiers
                .contains { specifier in
                    if case .simpleTypeSpecifier(let simple) = specifier {
                        return simple.specifier.tokenKind == .keyword(.inout)
                    }
                    return false
                } ?? false
            let isAutoclosure =
                parameter.type.as(AttributedTypeSyntax.self)?.attributes
                .contains { attribute in
                    if case .attribute(let attribute) = attribute {
                        return attribute.attributeName.trimmedDescription == "autoclosure"
                    }
                    return false
                } ?? false
            for attribute in parameter.attributes {
                guard case .attribute(let attribute) = attribute else {
                    throw unsupported("this attribute", parameter)
                }
                switch attribute.attributeName.trimmedDescription {
                case let name where facts.resultBuilders.contains(name):
                    resultBuilder = name
                default:
                    throw SyntaxError(
                        "unknown attribute '@\(attribute.attributeName.trimmedDescription)' (line \(line(of: attribute)))"
                    )
                }
            }
            let first = parameter.firstName.text
            let name = parameter.secondName?.text ?? first
            var type = TypeAnnotation.any
            var variadic = false
            if let written = Optional(parameter.type) {
                type = try self.type(written)
                if parameter.ellipsis != nil { variadic = true }
            }
            let defaultValue = try parameter.defaultValue.map { try expression($0.value) }
            return Parameter(
                label: first == "_" ? nil : first,
                name: name,
                type: type,
                variadic: variadic,
                defaultValue: defaultValue,
                isInout: isInout,
                isAutoclosure: isAutoclosure
            )
            .withBuilder(resultBuilder)
        }
    }

    /// `<T, U: Comparable>` and `where T: Equatable`: each type parameter, and the protocols it has
    /// to conform to. Anything else a `where` says (same-type requirements) is left unchecked.
    func genericParameters(
        _ clause: GenericParameterClauseSyntax?,
        where whereClause: GenericWhereClauseSyntax? = nil
    ) -> [GenericParameter] {
        var generics: [GenericParameter] = []
        for parameter in clause?.parameters ?? [] {
            generics.append(
                GenericParameter(
                    name: parameter.name.text,
                    constraints: parameter.inheritedType.map(constraints(of:)) ?? []
                )
            )
        }
        for requirement in whereClause?.requirements ?? [] {
            guard case .conformanceRequirement(let conformance) = requirement.requirement,
                let left = conformance.leftType.as(IdentifierTypeSyntax.self),
                let index = generics.firstIndex(where: { $0.name == left.name.text })
            else { continue }
            generics[index].constraints += constraints(of: conformance.rightType)
        }
        return generics
    }

    /// What `Comparable` or `Comparable & Hashable` asks of a type: it conforms to each.
    private func constraints(of type: TypeSyntax) -> [GenericParameter.Constraint] {
        if let composition = type.as(CompositionTypeSyntax.self) {
            return composition.elements.flatMap { constraints(of: $0.type) }
        }
        return [.conforms(to: .named(type.trimmedDescription))]
    }

    mutating func function(
        _ node: FunctionDeclSyntax,
        isMember: Bool = false
    ) throws -> FunctionDecl {
        // The type parameters, which its signature and body name.
        let generics = genericParameters(
            node.genericParameterClause,
            where: node.genericWhereClause
        )
        let outerParameters = typeParameters
        typeParameters.formUnion(generics.map(\.name))
        defer { typeParameters = outerParameters }
        let effects = node.signature.effectSpecifiers
        var parameters = try parameters(node.signature.parameterClause)
        // An operator's operands have no labels: its parameters' names are only for its body.
        if let first = node.name.text.first, !(first.isLetter || first == "_") {
            for index in parameters.indices { parameters[index].label = nil }
        }
        let returnType = try node.signature.returnClause.map { try type($0.type) }
        let mutating = node.modifiers.contains { $0.name.tokenKind == .keyword(.mutating) }
        // A prefix or postfix operator is told from the infix one of the same spelling by its name.
        var name = node.name.plainName
        if node.modifiers.contains(where: { $0.name.tokenKind == .keyword(.prefix) }) {
            name = "prefix " + name
        } else if node.modifiers.contains(where: { $0.name.tokenKind == .keyword(.postfix) }) {
            name = "postfix " + name
        }
        var thrownType = try effects?.throwsClause?.type.map { try type($0) }
        // `throws(Never)` throws nothing.
        if thrownType == .named("Never") { thrownType = nil }
        let isThrowing =
            effects?.throwsClause?.throwsSpecifier.tokenKind == .keyword(.throws)
            && !(effects?.throwsClause?.type != nil && thrownType == nil)
        let isRethrowing = effects?.throwsClause?.throwsSpecifier.tokenKind == .keyword(.rethrows)
        // In the prelude, a builtin's body is in Swift.
        guard let body = node.body else {
            guard prelude else { throw unsupported("a function without a body", node) }
            return FunctionDecl(
                name: name,
                parameters: parameters,
                returnType: returnType,
                body: Program(statements: []),
                documentation: documentation(of: node),
                isMutating: mutating,
                isThrowing: isThrowing,
                isAsync: effects?.asyncSpecifier != nil,
                isRethrowing: isRethrowing
            )
            .withAttributes(attributes(of: node.attributes))
        }
        locals.append(Set(parameters.map(\.name)))
        let outer = (tryDepth, leaving)
        tryDepth = 0
        leaving = Leaving(function: leaving.function + 1)
        anonymous.append(false)
        functionNames.append(name + "(" + parameters.map { ($0.label ?? "_") + ":" }.joined() + ")")
        defer {
            locals.removeLast(); (tryDepth, leaving) = outer; anonymous.removeLast();
            functionNames.removeLast()
        }
        let program = try block(body.statements, scoped: false)
        return FunctionDecl(
            name: name,
            parameters: parameters,
            returnType: returnType,
            body: program,
            documentation: documentation(of: node),
            isMutating: mutating,
            isThrowing: isThrowing,
            isAsync: effects?.asyncSpecifier != nil,
            isRethrowing: isRethrowing,
            generics: generics,
            names: NamesUsed(names: names(in: body))
        )
        .withBuilder(
            node.attributes
                .compactMap { attribute -> String? in
                    guard case .attribute(let named) = attribute else { return nil }
                    let name = named.attributeName.trimmedDescription
                    return facts.resultBuilders.contains(name) ? name : nil
                }
                .first
        )
        .withAttributes(attributes(of: node.attributes))
        .withThrown(thrownType)
        .withModifiers(
            override: node.modifiers.contains { $0.name.tokenKind == .keyword(.override) },
            nonisolated: node.modifiers.contains { $0.name.tokenKind == .keyword(.nonisolated) }
        )
    }

    mutating func initializer(_ node: InitializerDeclSyntax) throws -> FunctionDecl {
        guard node.optionalMark?.tokenKind != .exclamationMark else {
            throw unsupported("this initializer", node)
        }
        let outerParameters = typeParameters
        typeParameters.formUnion(
            genericParameters(node.genericParameterClause, where: node.genericWhereClause)
                .map(\.name)
        )
        defer { typeParameters = outerParameters }
        let parameters = try parameters(node.signature.parameterClause)
        guard let body = node.body else { throw unsupported("an initializer without a body", node) }
        locals.append(Set(parameters.map(\.name)))
        let outer = (tryDepth, leaving)
        tryDepth = 0
        leaving = Leaving(function: leaving.function + 1)
        anonymous.append(false)
        defer { locals.removeLast(); (tryDepth, leaving) = outer; anonymous.removeLast() }
        let program = try block(body.statements, scoped: false)
        var declaration = FunctionDecl(
            name: "init",
            parameters: parameters,
            body: program,
            documentation: documentation(of: node),
            isMutating: true,
            names: NamesUsed(names: names(in: body))
        )
        declaration.isFailable = node.optionalMark != nil
        declaration.isConvenience = node.modifiers.contains {
            $0.name.tokenKind == .keyword(.convenience)
        }
        declaration.isOverride = node.modifiers.contains {
            $0.name.tokenKind == .keyword(.override)
        }
        declaration.isNonisolated = node.modifiers.contains {
            $0.name.tokenKind == .keyword(.nonisolated)
        }
        return declaration
    }
}
