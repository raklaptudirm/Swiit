import SwiftSyntax

// Lowering member access, calls, subscripts and optional chains.

extension Lowering {
    mutating func member(
        _ node: MemberAccessExprSyntax,
        called: Bool = false
    ) throws -> Expr {
        guard node.declName.argumentNames == nil else {
            throw unsupported("a member with argument names", node)
        }
        let name = node.declName.baseName.plainName
        guard let base = node.base else { return .caseLiteral(name, nil) }
        // `x.self`, `Int.self`: the value, or the type, itself.
        if name == "self" { return try expression(base) }
        // `Outer.Inner`: a type declared inside another.
        if let reference = base.as(DeclReferenceExprSyntax.self) {
            let outer =
                reference.baseName.text == "Self"
                ? currentType : (nestedNames[reference.baseName.text] ?? reference.baseName.text)
            if let outer, declaredTypes.contains(outer + "." + name) {
                return .variable(outer + "." + name)
            }
            // A type inside another that an earlier program declared, or one of Swift's inside a
            // namespace: `Unicode.Scalar`.
            let base = reference.baseName.plainName
            if bound[base] == nil || bound[base] == .type, bound[base + "." + name] == .type {
                return .variable(base + "." + name)
            }
        }
        if let nested = base.as(MemberAccessExprSyntax.self),
            case .variable(let outer)? = try? member(nested),
            declaredTypes.contains(outer + "." + name) || bound[outer + "." + name] == .type
        {
            return .variable(outer + "." + name)
        }
        // `String.init`: the initializer as a function, which takes one value.
        if name == "init", !called, !base.is(SuperExprSyntax.self),
            !base.is(DeclReferenceExprSyntax.self)
                || base.as(DeclReferenceExprSyntax.self)?.baseName.text != "self"
        {
            let made = Expr.call(
                try expression(base),
                [Argument(label: nil, value: .variable("$0"))]
            )
            return .closure(
                ClosureLiteral(
                    parameters: [Parameter(name: "$0")],
                    returnType: nil,
                    body: Program(statements: [.expression(made)], lines: [line(of: node)]),
                    names: NamesUsed(names: ["$0"])
                )
            )
        }
        if let chained = base.as(OptionalChainingExprSyntax.self),
            chainPlaceholders[chained.id] == nil
        {
            return .optionalMember(try expression(chained.expression), name)
        }
        return .member(try expression(base), name)
    }

    mutating func arguments(_ list: LabeledExprListSyntax) throws -> [Argument] {
        try list.map { Argument(label: $0.label?.text, value: try expression($0.expression)) }
    }

    mutating func call(_ node: FunctionCallExprSyntax) throws -> Expr {
        // `.failed(code: 2)`: a case whose enum comes from context.
        let isCase =
            node.calledExpression.as(MemberAccessExprSyntax.self).map { $0.base == nil } ?? false
        // `[Int](repeating: 0, count: 3)`, `[String: Int]()`: an array or dictionary made, of the
        // type written.
        if let written = node.calledExpression.as(ArrayExprSyntax.self),
            written.elements.count == 1,
            let element = written.elements.first?.expression.as(DeclReferenceExprSyntax.self)
        {
            let made = Expr.call(.variable("Array"), try arguments(node.arguments))
            return .annotated(
                made,
                .list(
                    TypeAnnotation.spelled(element.baseName.text) ?? .named(element.baseName.text)
                )
            )
        }
        if let written = node.calledExpression.as(DictionaryExprSyntax.self),
            case .elements(let pairs) = written.content, pairs.count == 1,
            let pair = pairs.first, let key = pair.key.as(DeclReferenceExprSyntax.self),
            let value = pair.value.as(DeclReferenceExprSyntax.self)
        {
            let made = Expr.call(.variable("Dictionary"), try arguments(node.arguments))
            return .annotated(
                made,
                .dictionary(
                    TypeAnnotation.spelled(key.baseName.text) ?? .named(key.baseName.text),
                    TypeAnnotation.spelled(value.baseName.text) ?? .named(value.baseName.text)
                )
            )
        }
        // The callee first, as it is read: a name that isn't bound is found before
        // what is wrong with the arguments.
        var callee: Expr?
        if !isCase {
            if let reference = node.calledExpression.as(DeclReferenceExprSyntax.self),
                reference.baseName.text == "Optional",
                node.arguments.count == 1, node.arguments.first?.label == nil,
                names()["Optional"] == nil || names()["Optional"] == .type
            {
                // `Optional(x)`: x, as an optional.
                callee = .variable(InternalName.some)
            } else if let member = node.calledExpression.as(MemberAccessExprSyntax.self),
                member.declName.baseName.plainName == "init",
                let base = member.base, !base.is(SuperExprSyntax.self),
                base.as(DeclReferenceExprSyntax.self)?.baseName.text != "self"
            {
                // `Point.init(x: 1)` is `Point(x: 1)`.
                callee = try expression(base)
            } else if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
                // `3.5.rounded()`: a method of the number, not a unit.
                callee = try self.member(member, called: true)
            } else {
                callee = try expression(node.calledExpression)
            }
        }
        guard node.additionalTrailingClosures.isEmpty else {
            throw unsupported("more than one trailing closure", node)
        }
        var arguments = try arguments(node.arguments)
        if let trailing = node.trailingClosure {
            arguments.append(Argument(label: nil, value: .closure(try closure(trailing))))
        }
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self), isCase {
            return .caseLiteral(member.declName.baseName.plainName, arguments)
        }
        return .call(callee!, arguments)
    }

    /// The `x?` a postfix chain starts from, and how many links (members, subscripts, `!`; a call
    /// with its method counts once) are after it.
    func optionalChainCore(_ expr: ExprSyntax) -> (OptionalChainingExprSyntax, Int)? {
        var node = expr
        var depth = 0
        while true {
            if let chained = node.as(OptionalChainingExprSyntax.self) { return (chained, depth) }
            if let member = node.as(MemberAccessExprSyntax.self), let base = member.base {
                node = base; depth += 1
            } else if let subscripted = node.as(SubscriptCallExprSyntax.self) {
                node = subscripted.calledExpression; depth += 1
            } else if let unwrapped = node.as(ForceUnwrapExprSyntax.self) {
                node = unwrapped.expression; depth += 1
            } else if let call = node.as(FunctionCallExprSyntax.self) {
                node = call.calledExpression
                if !node.is(MemberAccessExprSyntax.self) { depth += 1 }
            } else {
                return nil
            }
        }
    }

    /// `o?.i.v` as `$chain(o) { $chain1 in $chain1.i.v }`: nil if `o` is, else what the rest gives.
    mutating func chain(
        _ expr: ExprSyntax,
        _ core: OptionalChainingExprSyntax
    ) throws -> Expr {
        chainCount += 1
        let name = InternalName.chainValue(chainCount)
        chainPlaceholders[core.id] = name
        defer { chainPlaceholders[core.id] = nil }
        locals.append([name])
        let rest = try expression(expr)
        locals.removeLast()
        let base = try expression(core.expression)
        let closure = ClosureLiteral(
            parameters: [Parameter(name: name)],
            body: Program(statements: [.expression(rest)], lines: [line(of: expr)]),
            names: NamesUsed(names: names(in: expr))
        )
        return .call(
            .variable(InternalName.chain),
            [Argument(value: base), Argument(value: .closure(closure))]
        )
    }

    mutating func subscriptCall(_ node: SubscriptCallExprSyntax) throws -> Expr {
        // The base first, as it is read: a name that isn't bound is found before
        // what is wrong with the subscript.
        let chained = node.calledExpression.as(OptionalChainingExprSyntax.self)
            .flatMap { chainPlaceholders[$0.id] == nil ? $0 : nil }
        let base = try expression(chained?.expression ?? node.calledExpression)
        // `value[keyPath: \.a.b]`: the member it names.
        if node.arguments.count == 1, let argument = node.arguments.first,
            argument.label?.text == "keyPath",
            let literal = argument.expression.as(KeyPathExprSyntax.self), literal.root == nil
        {
            guard case .keyPath(_, let path) = try keyPath(literal) else {
                throw unsupported("this key path", literal)
            }
            return path.reduce(base) { .member($0, $1) }
        }
        // `counts[word, default: 0]`.
        if node.arguments.count == 2, let key = node.arguments.first, key.label == nil,
            let fallback = node.arguments.last,
            fallback.label?.text == "default"
        {
            return .indexDefault(
                base,
                try expression(key.expression),
                try expression(fallback.expression)
            )
        }
        // `xs[2...]`, `xs[..<3]`, `xs[...3]`: what `suffix(from:)`, `prefix(upTo:)` and
        // `prefix(through:)` give.
        if node.arguments.count == 1, let argument = node.arguments.first, argument.label == nil {
            if let partial = argument.expression.as(PostfixOperatorExprSyntax.self),
                partial.operator.text == "..."
            {
                return .call(
                    .member(base, "suffix"),
                    [Argument(label: "from", value: try expression(partial.expression))]
                )
            }
            if let partial = argument.expression.as(PrefixOperatorExprSyntax.self),
                partial.operator.text == "..." || partial.operator.text == "..<"
            {
                let label = partial.operator.text == "..." ? "through" : "upTo"
                return .call(
                    .member(base, "prefix"),
                    [Argument(label: label, value: try expression(partial.expression))]
                )
            }
        }
        guard node.arguments.count == 1, let argument = node.arguments.first, argument.label == nil
        else {
            return .subscripted(base, try arguments(node.arguments))
        }
        let index = try expression(argument.expression)
        return chained != nil ? .optionalIndex(base, index) : .index(base, index)
    }
}
