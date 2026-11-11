import SwiftSyntax

// Lowering enums: their cases, raw and associated values, and members.

extension Lowering {
    mutating func enumeration(_ node: EnumDeclSyntax) throws -> EnumDecl {
        let outerParameters = typeParameters
        typeParameters.formUnion(
            genericParameters(node.genericParameterClause, where: node.genericWhereClause)
                .map(\.name)
        )
        defer { typeParameters = outerParameters }
        var rawType: TypeAnnotation?
        var conformances: [String] = []
        for inherited in node.inheritanceClause?.inheritedTypes ?? [] {
            let name = inherited.type.trimmedDescription
            if rawType == nil, conformances.isEmpty, let spelled = TypeAnnotation.spelled(name),
                [.int, .string, .double].contains(spelled)
            {
                rawType = spelled
            } else {
                conformances.append(name)
            }
        }
        try checkProtocols(conformances)
        var cases: [EnumCaseDecl] = []
        let qualified = typePrefix + node.name.text
        var declaration = EnumDecl(
            name: qualified,
            rawType: rawType,
            cases: [],
            conformances: conformances
        )
        declaration.typeParameters = node.genericParameterClause?.parameters.map(\.name.text) ?? []
        var (instanceMembers, staticMembers) = memberNames(of: node.memberBlock)
        if rawType != nil { instanceMembers.insert("rawValue") }
        members.append(instanceMembers)
        let outer = enter(type: node.name.text, members: node.memberBlock)
        defer { members.removeLast(); leave(type: outer) }
        for member in node.memberBlock.members {
            if let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) {
                for element in caseDecl.elements {
                    let associated: [AssociatedValue] =
                        try element.parameterClause?.parameters
                        .map { parameter in
                            AssociatedValue(
                                label: parameter.firstName?.text,
                                type: try type(parameter.type)
                            )
                        } ?? []
                    let raw = try element.rawValue.map { try expression($0.value) }
                    cases.append(
                        EnumCaseDecl(
                            name: element.name.plainName,
                            rawValue: raw,
                            associated: associated
                        )
                    )
                }
            } else if let variable = member.decl.as(VariableDeclSyntax.self) {
                let isStaticMember = isStatic(variable.modifiers)
                staticContext = isStaticMember ? (qualified, staticMembers) : nil
                defer { staticContext = nil }
                for property in try properties(variable) {
                    if isStaticMember {
                        declaration.staticProperties.append(property)
                    } else {
                        guard property.getter != nil else {
                            throw SyntaxError(
                                "an enum can't have a stored property: '\(property.name)' (line \(line(of: variable)))"
                            )
                        }
                        declaration.properties.append(property)
                    }
                }
            } else if let method = member.decl.as(FunctionDeclSyntax.self) {
                staticContext = isStatic(method.modifiers) ? (qualified, staticMembers) : nil
                defer { staticContext = nil }
                let lowered = try function(method, isMember: true)
                if isStatic(method.modifiers) {
                    declaration.staticMethods.append(lowered)
                } else {
                    declaration.methods.append(lowered)
                }
            } else if let initializerNode = member.decl.as(InitializerDeclSyntax.self) {
                declaration.initializers.append(try initializer(initializerNode))
            } else if member.decl.is(StructDeclSyntax.self) || member.decl.is(EnumDeclSyntax.self) {
                pendingNested += try self.declaration(member.decl)
            } else {
                throw unsupported("'\(member.decl.kind)' in an enum", member)
            }
        }
        declaration.cases = cases
        return declaration
    }
}
