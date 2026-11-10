import SwiftSyntax

// Lowering closures and key paths.

extension Lowering {
    mutating func closure(_ node: ClosureExprSyntax) throws -> ClosureLiteral {
        var parameters: [Parameter] = []
        var returnType: TypeAnnotation?
        var captures: [ClosureLiteral.Capture] = []
        if let signature = node.signature {
            guard signature.attributes.isEmpty else {
                throw unsupported("this closure signature", signature)
            }
            for item in signature.capture?.items ?? [] {
                let specifier = item.specifier?.specifier.tokenKind
                let isWeak = specifier == .keyword(.weak)
                guard item.specifier == nil || isWeak || specifier == .keyword(.unowned) else {
                    throw unsupported("this capture", item)
                }
                let name = item.name.text
                let value: Expr
                if let initializer = item.initializer {
                    value = try expression(initializer.value)
                } else {
                    value = reference(DeclReferenceExprSyntax(baseName: item.name))
                }
                captures.append(
                    ClosureLiteral.Capture(
                        name: name,
                        value: value,
                        isWeak: isWeak,
                        isUnowned: specifier == .keyword(.unowned)
                    )
                )
            }
            switch signature.parameterClause {
            case .simpleInput(let names)?:
                parameters = names.map { Parameter(name: $0.name.text) }
            case .parameterClause(let clause)?:
                parameters = try clause.parameters.map { parameter in
                    guard parameter.attributes.isEmpty else {
                        throw unsupported("an attribute on a closure's parameter", parameter)
                    }
                    let name = parameter.secondName?.text ?? parameter.firstName.text
                    return Parameter(
                        name: name,
                        type: try parameter.type.map { try type($0) } ?? .any
                    )
                }
            case nil:
                break
            }
            returnType = try signature.returnClause.map { try type($0.type) }
        } else {
            // `{ $0 * 2 }`: as many parameters as the highest `$n` it mentions.
            let arity = anonymousArity(in: node.statements)
            parameters = (0..<arity).map { Parameter(name: "$\($0)") }
        }
        locals.append(Set(parameters.map(\.name)))
        let outer = (tryDepth, leaving)
        tryDepth = 0
        leaving = Leaving(function: leaving.function + 1)
        anonymous.append(node.signature == nil)
        defer { locals.removeLast(); (tryDepth, leaving) = outer; anonymous.removeLast() }
        let body = try block(node.statements, scoped: false)
        var literal = ClosureLiteral(
            parameters: parameters,
            returnType: returnType,
            body: body,
            names: NamesUsed(names: names(in: node.statements))
        )
        literal.captures = captures
        return literal
    }

    /// The `$n` a closure's body mentions, outside the closures inside it,
    /// whose `$0` is their own: `{ xs.map { $0 * 2 } }` takes nothing.
    private func anonymousArity(in node: some SyntaxProtocol) -> Int {
        let counter = AnonymousArity()
        counter.walk(node)
        return counter.highest + 1
    }

    mutating func keyPath(_ node: KeyPathExprSyntax) throws -> Expr {
        var path: [String] = []
        for component in node.components {
            guard case .property(let property) = component.component else {
                throw unsupported("this key path component", component)
            }
            path.append(property.declName.baseName.plainName)
        }
        return .keyPath(root: node.root?.trimmedDescription, path: path)
    }
}
