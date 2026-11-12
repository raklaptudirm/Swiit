import SwiftSyntax

// Lowering subscripts.

extension Lowering {
    /// `subscript(i: Int) -> T { … }`. Its parameters take no label unless two names are written.
    mutating func subscriptDeclaration(_ node: SubscriptDeclSyntax) throws -> SubscriptDecl {
        guard node.genericParameterClause == nil, node.genericWhereClause == nil else {
            throw unsupported("a generic subscript", node)
        }
        var parameters = try self.parameters(node.parameterClause)
        for (index, written) in node.parameterClause.parameters.enumerated()
        where written.secondName == nil {
            parameters[index].label = nil
        }
        let returnType = try type(node.returnClause.type)
        guard let accessors = node.accessorBlock else {
            throw unsupported("a subscript without a body", node)
        }
        func body(
            _ items: CodeBlockItemListSyntax,
            _ extra: [String],
            _ lowering: inout Lowering
        ) throws -> Program {
            lowering.locals.append(Set(parameters.compactMap { $0.name } + extra))
            let outer = (lowering.tryDepth, lowering.leaving)
            lowering.tryDepth = 0
            lowering.leaving = Leaving(function: lowering.leaving.function + 1)
            lowering.anonymous.append(false)
            defer {
                lowering.locals.removeLast(); (lowering.tryDepth, lowering.leaving) = outer
                lowering.anonymous.removeLast()
            }
            return try lowering.block(items, scoped: false)
        }
        var declaration = SubscriptDecl(
            parameters: parameters,
            returnType: returnType,
            getter: Program(statements: [])
        )
        switch accessors.accessors {
        case .getter(let items):
            declaration.getter = try body(items, [], &self)
            declaration.getterNames = NamesUsed(names: names(in: items))
        case .accessors(let list):
            var sawGetter = false
            for accessor in list {
                guard let items = accessor.body?.statements else {
                    throw unsupported("an accessor without a body", accessor)
                }
                switch accessor.accessorSpecifier.tokenKind {
                case .keyword(.get):
                    declaration.getter = try body(items, [], &self)
                    declaration.getterNames = NamesUsed(names: names(in: items))
                    sawGetter = true
                case .keyword(.set):
                    declaration.setterName = accessor.parameters?.name.text ?? "newValue"
                    declaration.setter = try body(items, [declaration.setterName], &self)
                    declaration.setterNames = NamesUsed(names: names(in: items))
                default:
                    throw unsupported("this accessor", accessor)
                }
            }
            guard sawGetter else {
                throw SyntaxError("a subscript needs a 'get' (line \(line(of: node)))")
            }
        }
        return declaration
    }
}
