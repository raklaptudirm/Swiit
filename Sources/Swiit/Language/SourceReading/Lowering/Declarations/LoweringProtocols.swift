import SwiftSyntax

// Lowering protocols, and checking the protocols a type conforms to.

extension Lowering {
    /// `protocol Shape: Named { … }`: its requirements, which carry no bodies.
    mutating func protocolDeclaration(_ node: ProtocolDeclSyntax) throws -> ProtocolDecl {
        let name = typePrefix + node.name.text
        var declaration = ProtocolDecl(name: name)
        // `protocol P: class` limits it to classes, as AnyObject does.
        declaration.inherited =
            node.inheritanceClause?.inheritedTypes
            .map {
                $0.type.trimmedDescription == "class" ? "AnyObject" : $0.type.trimmedDescription
            } ?? []
        try checkProtocols(declaration.inherited)
        // The types the conforming type chooses are only known to it.
        let outerParameters = typeParameters
        defer { typeParameters = outerParameters }
        for member in node.memberBlock.members {
            if let associated = member.decl.as(AssociatedTypeDeclSyntax.self) {
                declaration.associatedTypes.append(associated.name.text)
                typeParameters.insert(associated.name.text)
            }
        }
        let outerCurrent = currentType
        currentType = name
        defer { currentType = outerCurrent }
        for member in node.memberBlock.members {
            if let method = member.decl.as(FunctionDeclSyntax.self) {
                let generics = genericParameters(
                    method.genericParameterClause,
                    where: method.genericWhereClause
                )
                let methodParameters = typeParameters
                typeParameters.formUnion(generics.map(\.name))
                defer { typeParameters = methodParameters }
                let effects = method.signature.effectSpecifiers
                let lowered = FunctionDecl(
                    name: method.name.plainName,
                    parameters: try parameters(method.signature.parameterClause),
                    returnType: try method.signature.returnClause.map { try type($0.type) },
                    body: Program(statements: []),
                    isMutating: method.modifiers.contains {
                        $0.name.tokenKind == .keyword(.mutating)
                    },
                    isThrowing: effects?.throwsClause?.throwsSpecifier.tokenKind
                        == .keyword(.throws),
                    isAsync: effects?.asyncSpecifier != nil,
                    generics: generics
                )
                if isStatic(method.modifiers) {
                    declaration.staticMethods.append(lowered)
                } else {
                    declaration.methods.append(lowered)
                }
            } else if let variable = member.decl.as(VariableDeclSyntax.self) {
                for binding in variable.bindings {
                    guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self),
                        let annotation = binding.typeAnnotation
                    else {
                        throw unsupported("this requirement", binding)
                    }
                    var settable = false
                    if case .accessors(let list)? = binding.accessorBlock?.accessors {
                        settable = list.contains {
                            $0.accessorSpecifier.tokenKind == .keyword(.set)
                        }
                    }
                    let property = ProtocolProperty(
                        name: identifier.identifier.plainName,
                        type: try type(annotation.type),
                        settable: settable
                    )
                    if isStatic(variable.modifiers) {
                        declaration.staticProperties.append(property)
                    } else {
                        declaration.properties.append(property)
                    }
                }
            } else if let initializerNode = member.decl.as(InitializerDeclSyntax.self) {
                declaration.initializers.append(
                    FunctionDecl(
                        name: "init",
                        parameters: try parameters(initializerNode.signature.parameterClause),
                        body: Program(statements: []),
                        isMutating: true,
                        isThrowing: initializerNode.signature.effectSpecifiers?.throwsClause != nil
                    )
                )
            } else if !member.decl.is(AssociatedTypeDeclSyntax.self)
                && !member.decl.is(TypeAliasDeclSyntax.self)
            {
                throw unsupported("'\(member.decl.kind)' in a protocol", member)
            }
        }
        return declaration
    }

    /// What a type can say it conforms to: the protocols Swiit has, and those declared.
    func checkProtocols(_ names: [String]) throws {
        for name in names
        where !Lowering.protocols.contains(name)
            && !declaredTypes.contains(nestedNames[name] ?? name)
            && bound[name] != .type
        {
            throw SyntaxError(
                "unknown protocol '\(name)'; Swiit has \(Lowering.protocols.sorted().joined(separator: ", "))"
            )
        }
    }

    /// The first group has a meaning here (the checker checks what they ask
    /// for); the second are markers Swift's own code writes, with nothing to
    /// check or do yet.
    static let protocols: Set = [
        "Equatable", "Hashable", "Comparable", "CustomStringConvertible", "Encodable", "Sequence",
        "Error",
        "CaseIterable", "Sendable", "Decodable", "Codable", "AnyObject",
        "CustomDebugStringConvertible",
        "Collection", "BidirectionalCollection", "RandomAccessCollection", "MutableCollection",
        "RangeReplaceableCollection",
        "Numeric", "SignedNumeric", "BinaryInteger", "FixedWidthInteger", "SignedInteger",
        "UnsignedInteger",
        "FloatingPoint", "BinaryFloatingPoint", "IteratorProtocol", "LosslessStringConvertible",
        "Identifiable",
        "ExpressibleByArrayLiteral", "ExpressibleByStringLiteral", "ExpressibleByIntegerLiteral",
    ]
}
