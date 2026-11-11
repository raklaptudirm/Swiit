import SwiftSyntax

extension Lowering {
    // MARK: Declarations

    mutating func declaration(_ decl: DeclSyntax) throws -> [Statement] {
        if let node = decl.as(VariableDeclSyntax.self) { return try variables(node) }
        if let node = decl.as(FunctionDeclSyntax.self) {
            functions.insert(node.name.plainName)
            bind(node.name.text)
            return [.function(try function(node))]
        }
        if let node = decl.as(ProtocolDeclSyntax.self) {
            return [.protocolDecl(try protocolDeclaration(node))]
        }
        // `infix operator **`, `precedencegroup Power { … }`: kept, for later programs to fold by.
        if let node = decl.as(OperatorDeclSyntax.self) {
            return [
                .operatorDeclaration(
                    key: "operator \(node.name.text)",
                    source: node.trimmedDescription
                )
            ]
        }
        if let node = decl.as(PrecedenceGroupDeclSyntax.self) {
            return [
                .operatorDeclaration(
                    key: "precedencegroup \(node.name.text)",
                    source: node.trimmedDescription
                )
            ]
        }
        if let node = decl.as(StructDeclSyntax.self) {
            let lowered = try structure(node)
            return takeNested() + [.structDecl(lowered)]
        }
        if let node = decl.as(EnumDeclSyntax.self) {
            let lowered = try enumeration(node)
            return takeNested() + [.enumDecl(lowered)]
        }
        if let node = decl.as(ClassDeclSyntax.self) {
            let lowered = try classDeclaration(
                node.name.text,
                node.genericParameterClause,
                node.genericWhereClause,
                node.inheritanceClause,
                node.memberBlock,
                isActor: false,
                node: node
            )
            return takeNested() + [.classDecl(lowered)]
        }
        if let node = decl.as(ActorDeclSyntax.self) {
            let lowered = try classDeclaration(
                node.name.text,
                node.genericParameterClause,
                node.genericWhereClause,
                node.inheritanceClause,
                node.memberBlock,
                isActor: true,
                node: node
            )
            return takeNested() + [.classDecl(lowered)]
        }
        // The prelude's `Sequence` extension declares its methods; any other type's is an ordinary
        // extension, its bodies in Swiit.
        if prelude, let node = decl.as(ExtensionDeclSyntax.self),
            node.extendedType.trimmedDescription == "Sequence"
        {
            return [try sequenceExtension(node)]
        }
        if let node = decl.as(ExtensionDeclSyntax.self) { return try typeExtension(node) }
        if let node = decl.as(ImportDeclSyntax.self) { return try importDeclaration(node) }
        if let node = decl.as(IfConfigDeclSyntax.self) { return try conditional(node) }
        if let node = decl.as(TypeAliasDeclSyntax.self) {
            guard node.genericParameterClause == nil else {
                throw unsupported("a generic typealias", node)
            }
            aliases[node.name.text] = try type(node.initializer.value)
            return []
        }
        throw unsupported("'\(decl.kind)'", decl)
    }

    /// `import Foundation`: what the interpreter already has, so nothing to do.
    /// Any other module isn't there to import yet.
    private func importDeclaration(_ node: ImportDeclSyntax) throws -> [Statement] {
        guard node.importKindSpecifier == nil, let module = node.path.first, node.path.count == 1
        else {
            throw unsupported("this import", node)
        }
        guard Lowering.modules.contains(module.name.text) else {
            throw SyntaxError(
                "no such module '\(module.name.text)'; Swiit has \(Lowering.modules.sorted().joined(separator: ", ")) (line \(line(of: node)))"
            )
        }
        return []
    }

    /// The modules whose declarations are always there.
    /// Swift's other integer types, which Swiit reads as Int.
    static let fixedWidthIntegers: Set<String> = [
        "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
    ]
    /// Types Swift's standard library spells two ways: the old name, and the type it is.
    static let swiftAliases = ["UnicodeScalar": "Unicode.Scalar"]
    static let modules: Set<String> = [
        "Swift", "Foundation", "SystemPackage", "Swiit", "_StringProcessing",
    ]

    /// The `///` lines above a declaration: the summary, and `- Parameter x:` lines.
    func documentation(of node: some SyntaxProtocol) -> Documentation? {
        var lines: [String] = []
        for piece in node.leadingTrivia {
            if case .docLineComment(let text) = piece {
                var line = String(text.dropFirst(3))
                if line.first == " " { line.removeFirst() }
                lines.append(line)
            } else if case .newlines(let count) = piece, count > 1 {
                lines.removeAll()
            }
        }
        guard !lines.isEmpty else { return nil }
        var summary: [String] = []
        var parameters: [String: String] = [:]
        for line in lines {
            if line.hasPrefix("- Parameter "), let colon = line.firstIndex(of: ":") {
                let name = line[line.index(line.startIndex, offsetBy: 12)..<colon]
                    .trimmingCharacters(in: .whitespaces)
                parameters[name] = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
            } else {
                summary.append(line)
            }
        }
        return Documentation(
            summary: summary.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            parameters: parameters
        )
    }
}
