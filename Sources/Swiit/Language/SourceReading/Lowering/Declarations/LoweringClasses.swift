import SwiftSyntax

// Lowering classes.

extension Lowering {
    // swiftlint:disable function_parameter_count - it threads one state through; splitting it is item 17 of Docs/agenda.md
    /// `class Dog: Animal { … }`, `actor Counter { … }`.
    mutating func classDeclaration(
        _ written: String,
        _ generics: GenericParameterClauseSyntax?,
        _ whereClause: GenericWhereClauseSyntax?,
        _ inheritance: InheritanceClauseSyntax?,
        _ block: MemberBlockSyntax,
        isActor: Bool,
        node: some SyntaxProtocol
    ) throws -> ClassDecl {
        let outerParameters = typeParameters
        typeParameters.formUnion(genericParameters(generics, where: whereClause).map(\.name))
        defer { typeParameters = outerParameters }
        // `Base<String>` is Base: its arguments only say what it holds.
        let inherited =
            inheritance?.inheritedTypes
            .map { inheritedType -> String in
                let text = inheritedType.type.trimmedDescription
                return text.firstIndex(of: "<").map { String(text[..<$0]) } ?? text
            } ?? []
        try checkProtocols(inherited)
        let qualified = typePrefix + written
        var members = StructDecl(
            name: qualified,
            properties: [],
            methods: [],
            initializers: [],
            conformances: []
        )
        var declaration = ClassDecl(
            name: qualified,
            inherited: inherited,
            members: members,
            deinitializer: nil,
            isActor: isActor
        )
        var (instanceMembers, staticMembers) = memberNames(of: block)
        // What it inherits from the classes above, which its bodies name as their own.
        var above = inherited.first
        var seen: Set<String> = []
        while let superclass = above, seen.insert(superclass).inserted {
            instanceMembers.formUnion(facts.instanceMembers[superclass] ?? [])
            above = facts.superclass[superclass]
        }
        self.members.append(instanceMembers)
        let outer = enter(type: written, members: block)
        defer { self.members.removeLast(); leave(type: outer) }
        try lowerMembers(of: block, owner: qualified, staticMembers: staticMembers, into: &members)
        members.isDynamicMemberLookup = hasAttribute(
            "dynamicMemberLookup",
            node.as(ClassDeclSyntax.self)?.attributes ?? node.as(ActorDeclSyntax.self)?.attributes
                ?? []
        )
        declaration.members = members
        // `deinit { … }`.
        for member in block.members {
            guard let deinitializer = member.decl.as(DeinitializerDeclSyntax.self),
                let body = deinitializer.body
            else {
                continue
            }
            let outerState = (tryDepth, leaving)
            tryDepth = 0
            leaving = Leaving(function: leaving.function + 1)
            anonymous.append(false)
            locals.append([])
            defer { locals.removeLast(); (tryDepth, leaving) = outerState; anonymous.removeLast() }
            declaration.deinitializer = try self.block(body.statements, scoped: false)
            declaration.deinitializerNames = NamesUsed(names: names(in: body))
        }
        return declaration
    }
    // swiftlint:enable function_parameter_count
}
