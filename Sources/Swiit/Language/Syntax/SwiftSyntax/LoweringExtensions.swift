import SwiftSyntax

extension Lowering {
    // MARK: Extensions

    /// `extension Int { … }`, `extension Point: Equatable { … }`: members added to a type, whichever
    /// the type is. A `where` clause is accepted and not checked. Inside, a name that isn't local is
    /// the type's own member if it has one; the checker finds which (`TypeChecker.variable`).
    mutating func typeExtension(_ node: ExtensionDeclSyntax) throws -> [Statement] {
        guard let written = typeName(node.extendedType) else { throw unsupported("this extension", node) }
        let outerParameters = typeParameters
        defer { typeParameters = outerParameters }
        // A type declared inside another, or by the short name it goes by there.
        let target = nestedNames[written] ?? written
        let conformances = node.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
        try checkProtocols(conformances)
        var declaration = StructDecl(name: target, properties: [], methods: [], initializers: [], conformances: [])
        let (instanceMembers, staticMembers) = memberNames(of: node.memberBlock)
        members.append(instanceMembers)
        let outer = (typePrefix, currentType, nestedNames, typeParameters)
        currentType = target
        typePrefix = target + "."
        // What a collection's members call its items.
        switch written {
        case "Array", "ArraySlice", "Set", "Sequence", "Collection", "BidirectionalCollection", "RandomAccessCollection": typeParameters = ["Element"]
        case "Dictionary": typeParameters = ["Key", "Value"]
        default: break
        }
        defer { members.removeLast(); (typePrefix, currentType, nestedNames, typeParameters) = outer }
        try lowerMembers(of: node.memberBlock, owner: target, staticMembers: staticMembers, into: &declaration)
        for property in declaration.properties where property.getter == nil {
            throw SyntaxError("an extension can't add a stored property: '\(property.name)' (line \(line(of: node)))")
        }
        guard declaration.initializers.isEmpty else { throw unsupported("an initializer in an extension", node) }
        guard declaration.subscripts.isEmpty else { throw unsupported("a subscript in an extension", node) }
        return takeNested() + [.typeExtension(ExtensionDecl(typeName: target, members: declaration, conformances: conformances))]
    }

    /// The name an extended type is written with: `Int`, `Outer.Inner`, or `Array<Int>`'s `Array`.
    private func typeName(_ type: TypeSyntax) -> String? {
        if let identifier = type.as(IdentifierTypeSyntax.self) { return identifier.name.text }
        if let member = type.as(MemberTypeSyntax.self), let base = typeName(member.baseType) { return base + "." + member.name.text }
        if let array = type.as(ArrayTypeSyntax.self), array.element.is(IdentifierTypeSyntax.self) { return "Array" }
        return nil
    }
}
