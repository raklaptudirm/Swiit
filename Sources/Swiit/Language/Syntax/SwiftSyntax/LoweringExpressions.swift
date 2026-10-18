import SwiftSyntax
import SwiitKit

extension Lowering {
    // MARK: Expressions

    mutating func expression(_ expr: ExprSyntax) throws -> Expr {
        let lowered = try expressionNode(expr)
        // Where it was written, for an error in it to point at.
        if recordsSpots { currentSpots.append(Spot(expression: lowered, range: range(of: expr))) }
        return lowered
    }

    private mutating func expressionNode(_ expr: ExprSyntax) throws -> Expr {
        // `$(…)`, `$name` and `async …` are the layer's, not Swift's.
        if plugin != nil, isLayerExpression(expr),
           let lowered = try layerExpression(at: expr.positionAfterSkippingLeadingTrivia.utf8Offset) {
            return lowered
        }
        // `o?.i.v`: what follows the `?` goes on only if `o` has a value.
        if let (core, depth) = optionalChainCore(expr) {
            if depth >= 2, chainPlaceholders[core.id] == nil { return try chain(expr, core) }
        }
        if let node = expr.as(OptionalChainingExprSyntax.self), let placeholder = chainPlaceholders[node.id] { return .variable(placeholder) }
        if let node = expr.as(IntegerLiteralExprSyntax.self) {
            let text = node.literal.text.replacingOccurrences(of: "_", with: "")
            guard let number = Int(text) ?? parseRadix(text) else { throw unsupported("this integer", node) }
            return .literal(.int(number))
        }
        if let node = expr.as(FloatLiteralExprSyntax.self) {
            guard let number = Double(node.literal.text.replacingOccurrences(of: "_", with: "")) else { throw unsupported("this number", node) }
            return .literal(.double(number))
        }
        if let node = expr.as(BooleanLiteralExprSyntax.self) { return .literal(.bool(node.literal.tokenKind == .keyword(.true))) }
        if expr.is(NilLiteralExprSyntax.self) { return .literal(.nothing) }
        if let node = expr.as(StringLiteralExprSyntax.self) { return try string(node) }
        if let node = expr.as(DeclReferenceExprSyntax.self) {
            // `+`, `<`: an operator as a function, as in `reduce(0, +)`.
            if case .binaryOperator = node.baseName.tokenKind, let op = binaryOperator(node.baseName.text) {
                let body = Expr.binary(op, .variable("$0"), .variable("$1"))
                return .closure(ClosureLiteral(
                    parameters: [Parameter(name: "$0"), Parameter(name: "$1")], returnType: nil,
                    body: Program(statements: [.expression(body)], lines: [line(of: node)]), names: NamesUsed(names: ["$0", "$1"])
                ))
            }
            try checkKnown(node, calling: false)
            return reference(node)
        }
        if let node = expr.as(MemberAccessExprSyntax.self) { return try member(node) }
        if let node = expr.as(FunctionCallExprSyntax.self) { return try call(node) }
        if let node = expr.as(SubscriptCallExprSyntax.self) { return try subscriptCall(node) }
        if let node = expr.as(ArrayExprSyntax.self) { return .list(try node.elements.map { try expression($0.expression) }) }
        if let node = expr.as(DictionaryExprSyntax.self) { return try dictionary(node) }
        if let node = expr.as(TupleExprSyntax.self) { return try tuple(node) }
        if let node = expr.as(ClosureExprSyntax.self) { return .closure(try closure(node)) }
        if let node = expr.as(PrefixOperatorExprSyntax.self) { return try prefix(node) }
        if let node = expr.as(ForceUnwrapExprSyntax.self) { return .forceUnwrap(try expression(node.expression)) }
        if let node = expr.as(PostfixOperatorExprSyntax.self), node.operator.text != "..." {
            return .call(.variable("postfix " + node.operator.text), [Argument(value: try expression(node.expression))])
        }
        if let node = expr.as(InfixOperatorExprSyntax.self) { return try infix(node) }
        if let node = expr.as(TernaryExprSyntax.self) { return try ternary(node) }
        if let node = expr.as(AsExprSyntax.self) {
            let kind: CastKind = switch node.questionOrExclamationMark?.tokenKind {
            case .postfixQuestionMark?: .conditional
            case .exclamationMark?: .forced
            default: .upcast
            }
            return .cast(try expression(node.expression), try type(node.type), kind)
        }
        if let node = expr.as(IsExprSyntax.self) { return .cast(try expression(node.expression), try type(node.type), .check) }
        if let node = expr.as(TryExprSyntax.self) {
            let kind: TryKind = switch node.questionOrExclamationMark?.tokenKind {
            case .postfixQuestionMark?: .optional
            case .exclamationMark?: .forced
            default: .plain
            }
            tryDepth += 1
            defer { tryDepth -= 1 }
            return .attempt(try expression(node.expression), kind)
        }
        if let node = expr.as(AwaitExprSyntax.self) {
            // A bare `await` waits for the jobs in the background, so the
            // expression SwiftParser finds missing is not a problem.
            if node.expression.is(MissingExprSyntax.self) {
                accepted.insert(node.expression.id)
                return .await(nil, throwing: tryDepth > 0)
            }
            return .await(try expression(node.expression), throwing: tryDepth > 0)
        }
        if expr.is(SuperExprSyntax.self) { return .variable("super") }
        if let node = expr.as(KeyPathExprSyntax.self) { return try keyPath(node) }
        // `Box<Int>(…)`, `f<Int>(…)`: the types only say what a call would infer.
        if let node = expr.as(GenericSpecializationExprSyntax.self) { return try expression(node.expression) }
        if let node = expr.as(InOutExprSyntax.self) { return .inoutArgument(try expression(node.expression)) }
        if let node = expr.as(IfExprSyntax.self) {
            let statement = try ifStatement(node)
            guard statement.otherwise != nil else { throw SyntaxError("an if expression needs an else (line \(line(of: node)))") }
            guard let lowered = statement.asExpression else {
                throw SyntaxError("each branch of an if expression must be one expression (line \(line(of: node)))")
            }
            return .ifExpression(lowered)
        }
        if let node = expr.as(MacroExpansionExprSyntax.self), node.macroName.text == "filePath" { return .filePath }
        if let node = expr.as(MacroExpansionExprSyntax.self), node.macroName.text == "function" { return .literal(.string(functionNames.last ?? "")) }
        if let node = expr.as(MacroExpansionExprSyntax.self), node.macroName.text == "line" { return .literal(.int(line(of: node))) }
        // `x?` alone: Swift's optional chaining goes on with a member or a subscript, which are lowered with their base.
        if let node = expr.as(OptionalChainingExprSyntax.self) {
            failedAt = node.questionMark.positionAfterSkippingLeadingTrivia.utf8Offset
            throw SyntaxError("unexpected '?'")
        }
        throw unsupported("'\(expr.kind)'", expr)
    }

    private func parseRadix(_ text: String) -> Int? {
        let lowered = text.lowercased()
        if lowered.hasPrefix("0x") { return Int(lowered.dropFirst(2), radix: 16) }
        if lowered.hasPrefix("0b") { return Int(lowered.dropFirst(2), radix: 2) }
        if lowered.hasPrefix("0o") { return Int(lowered.dropFirst(2), radix: 8) }
        return nil
    }

    // MARK: Names

    /// A name: a local, a member of the struct whose method this is (read
    /// through `self`), or a global.
    func reference(_ node: DeclReferenceExprSyntax) -> Expr {
        let name = node.baseName.text
        if locals.contains(where: { $0.contains(name) }) { return .variable(name) }
        if name == "Self", let current = currentType { return .variable(current) }
        if let nested = nestedNames[name] { return .variable(nested) }
        // A type alias, used where the type is (`BChar()`): the type it stands for.
        if let alias = aliases[name] {
            if case .named(let target) = alias { return .variable(target) }
            if let (target, _) = alias.swiftType { return .variable(target) }
        }
        // A computed variable is read by its getter.
        if facts.computedGlobals.contains(name) { return .call(.variable("$get_" + name), []) }
        if let context = staticContext, context.names.contains(name) { return .member(.variable(context.owner), name) }
        if members.last?.contains(name) == true { return .member(.variable("self"), name) }
        // The fixed-width integers are Int here, without its overflow rules.
        if Lowering.fixedWidthIntegers.contains(name), bound[name] == nil, !declaredTypes.contains(name) { return .variable("Int") }
        if let target = Lowering.swiftAliases[name], bound[name] == nil, !declaredTypes.contains(name) { return .variable(target) }
        return .variable(name)
    }

    // MARK: Literals

    private mutating func string(_ node: StringLiteralExprSyntax) throws -> Expr {
        // `'a b'`: a raw string, which SwiftParser reads with its quotes missing.
        if let open = node.unexpectedBetweenOpeningPoundsAndOpeningQuote?.first?.as(TokenSyntax.self), open.tokenKind == .singleQuote {
            guard let close = node.unexpectedBetweenSegmentsAndClosingQuote?.first?.as(TokenSyntax.self), close.tokenKind == .singleQuote else {
                throw SyntaxError.incomplete("unterminated string (line \(line(of: node)))")
            }
            accepted.insert(node.id)
            extentHints.append(close.endPositionBeforeTrailingTrivia.utf8Offset)
            let text = bytes[open.endPositionBeforeTrailingTrivia.utf8Offset..<close.positionAfterSkippingLeadingTrivia.utf8Offset]
            return .literal(.string(String(decoding: text, as: UTF8.self)))
        }
        // `"…"`, `"""…"""` and either with `#` delimiters, where an escape is `\#n`.
        let pounds = node.openingPounds?.text.count ?? 0
        let multiline = node.openingQuote.tokenKind == .multilineStringQuote
        guard node.openingQuote.tokenKind == .stringQuote || multiline else {
            throw unsupported("this string", node)
        }
        // A multi-line string drops the closing quotes' indentation from every line.
        var indent = ""
        if multiline {
            let trivia = node.closingQuote.leadingTrivia.description
            indent = String(trivia.split(separator: "\n", omittingEmptySubsequences: false).last ?? "")
            guard indent.allSatisfy({ $0 == " " || $0 == "\t" }) else { throw unsupported("this string", node) }
        }
        var parts: [StringPart] = []
        var text = ""
        var atLineStart = multiline
        func flush() { if !text.isEmpty { parts.append(.literal(text)); text = "" } }
        for segment in node.segments {
            switch segment {
            case .stringSegment(let literal):
                var raw = literal.content.text
                if multiline && !indent.isEmpty {
                    var lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                    for index in lines.indices where index > 0 || atLineStart {
                        if lines[index].hasPrefix(indent) { lines[index].removeFirst(indent.count) }
                        else if lines[index].allSatisfy({ $0 == " " || $0 == "\t" }) { lines[index] = "" }
                    }
                    raw = lines.joined(separator: "\n")
                }
                if multiline { atLineStart = raw.hasSuffix("\n") }
                guard let unescaped = unescape(raw, pounds: pounds) else {
                    throw SyntaxError("invalid escape in string: write \\\\ for a backslash, or use single quotes ('…') to keep every backslash (line \(line(of: literal)))")
                }
                text += unescaped
            case .expressionSegment(let interpolation):
                guard interpolation.expressions.count == 1, let inner = interpolation.expressions.first else {
                    throw unsupported("this interpolation", interpolation)
                }
                flush()
                atLineStart = false
                parts.append(.expression(try expression(inner.expression)))
            }
        }
        // The newline before the closing quotes isn't part of a multi-line string.
        if multiline, text.hasSuffix("\n") { text.removeLast() }
        flush()
        if parts.isEmpty { return .literal(.string("")) }
        if parts.count == 1, case .literal(let only) = parts[0] { return .literal(.string(only)) }
        return .string(parts)
    }

    /// A string's text with its escapes made: `\n`, or with `#` delimiters `\#n`
    /// (a `\` alone is itself there).
    private func unescape(_ text: String, pounds: Int = 0) -> String? {
        let introducer = Array("\\" + String(repeating: "#", count: pounds))
        let characters = Array(text)
        var result = ""
        var index = 0
        while index < characters.count {
            guard characters[index...].starts(with: introducer) else {
                result.append(characters[index])
                index += 1
                continue
            }
            index += introducer.count
            guard index < characters.count else { return nil }
            let next = characters[index]
            index += 1
            switch next {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "0": result.append("\0")
            case "\\": result.append("\\")
            case "\"": result.append("\"")
            case "'": result.append("'")
            case "\n": break // A line continuation, in a multi-line string.
            case "u":
                guard index < characters.count, characters[index] == "{" else { return nil }
                index += 1
                var digits = ""
                while index < characters.count, characters[index] != "}" { digits.append(characters[index]); index += 1 }
                index += 1
                guard let value = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(value) else { return nil }
                result.unicodeScalars.append(scalar)
            default: return nil
            }
        }
        return result
    }

    // MARK: Members, calls, subscripts

    private mutating func member(_ node: MemberAccessExprSyntax, called: Bool = false) throws -> Expr {
        guard node.declName.argumentNames == nil else { throw unsupported("a member with argument names", node) }
        let name = node.declName.baseName.text
        guard let base = node.base else { return .caseLiteral(name, nil) }
        // `x.self`, `Int.self`: the value, or the type, itself.
        if name == "self" { return try expression(base) }
        // `Outer.Inner`: a type declared inside another.
        if let reference = base.as(DeclReferenceExprSyntax.self) {
            let outer = reference.baseName.text == "Self" ? currentType : (nestedNames[reference.baseName.text] ?? reference.baseName.text)
            if let outer, declaredTypes.contains(outer + "." + name) { return .variable(outer + "." + name) }
            // A type inside another that an earlier program declared, or one of Swift's inside a namespace: `Unicode.Scalar`.
            let base = reference.baseName.text
            if bound[base] == nil || bound[base] == .type, bound[base + "." + name] == .type { return .variable(base + "." + name) }
        }
        if let nested = base.as(MemberAccessExprSyntax.self), case .variable(let outer)? = try? member(nested), declaredTypes.contains(outer + "." + name) || bound[outer + "." + name] == .type {
            return .variable(outer + "." + name)
        }
        // `String.init`: the initializer as a function, which takes one value.
        if name == "init", !called, !base.is(SuperExprSyntax.self), !base.is(DeclReferenceExprSyntax.self) || base.as(DeclReferenceExprSyntax.self)?.baseName.text != "self" {
            let made = Expr.call(try expression(base), [Argument(label: nil, value: .variable("$0"))])
            return .closure(ClosureLiteral(
                parameters: [Parameter(name: "$0")], returnType: nil,
                body: Program(statements: [.expression(made)], lines: [line(of: node)]), names: NamesUsed(names: ["$0"])
            ))
        }
        // `2.mb`: a file size, written as a number and its unit.
        if FileSize.units[name] != nil {
            if let integer = base.as(IntegerLiteralExprSyntax.self), let amount = Double(integer.literal.text.replacingOccurrences(of: "_", with: "")) {
                return try fileSize(amount, name, node)
            }
            if let float = base.as(FloatLiteralExprSyntax.self), let amount = Double(float.literal.text.replacingOccurrences(of: "_", with: "")) {
                return try fileSize(amount, name, node)
            }
        }
        // `1.parsecs`: a number is followed by a unit, and this isn't one.
        if !called, plugin != nil, base.is(IntegerLiteralExprSyntax.self) || base.is(FloatLiteralExprSyntax.self) {
            failedAt = node.declName.endPositionBeforeTrailingTrivia.utf8Offset
            throw SyntaxError("unknown unit '\(name)'; file sizes use b, kb, mb, gb, tb, or kib, mib, gib, tib")
        }
        if let chained = base.as(OptionalChainingExprSyntax.self), chainPlaceholders[chained.id] == nil {
            return .optionalMember(try expression(chained.expression), name)
        }
        return .member(try expression(base), name)
    }

    private func fileSize(_ amount: Double, _ unit: String, _ node: some SyntaxProtocol) throws -> Expr {
        guard let size = FileSize(amount, unit: unit) else { throw SyntaxError("file size \(amount).\(unit) is too large") }
        return .literal(.fileSize(size))
    }

    mutating func arguments(_ list: LabeledExprListSyntax) throws -> [Argument] {
        try list.map { Argument(label: $0.label?.text, value: try expression($0.expression)) }
    }

    private mutating func call(_ node: FunctionCallExprSyntax) throws -> Expr {
        // `.failed(code: 2)`: a case whose enum comes from context.
        let isCase = node.calledExpression.as(MemberAccessExprSyntax.self).map { $0.base == nil } ?? false
        // `[Int](repeating: 0, count: 3)`, `[String: Int]()`: an array or dictionary made, of the type written.
        if let written = node.calledExpression.as(ArrayExprSyntax.self), written.elements.count == 1,
           let element = written.elements.first?.expression.as(DeclReferenceExprSyntax.self) {
            let made = Expr.call(.variable("Array"), try arguments(node.arguments))
            return .annotated(made, .list(TypeAnnotation.spelled(element.baseName.text) ?? .named(element.baseName.text)))
        }
        if let written = node.calledExpression.as(DictionaryExprSyntax.self), case .elements(let pairs) = written.content, pairs.count == 1,
           let pair = pairs.first, let key = pair.key.as(DeclReferenceExprSyntax.self), let value = pair.value.as(DeclReferenceExprSyntax.self) {
            let made = Expr.call(.variable("Dictionary"), try arguments(node.arguments))
            return .annotated(made, .dictionary(TypeAnnotation.spelled(key.baseName.text) ?? .named(key.baseName.text),
                                                TypeAnnotation.spelled(value.baseName.text) ?? .named(value.baseName.text)))
        }
        // The callee first, as it is read: a name that isn't bound is found before
        // what is wrong with the arguments.
        var callee: Expr?
        if !isCase {
            if let reference = node.calledExpression.as(DeclReferenceExprSyntax.self), reference.baseName.text == "Optional",
               node.arguments.count == 1, node.arguments.first?.label == nil, names()["Optional"] == nil || names()["Optional"] == .type {
                // `Optional(x)`: x, as an optional.
                callee = .variable("$some")
            } else if let reference = node.calledExpression.as(DeclReferenceExprSyntax.self), strictNames, !isLayerExpression(ExprSyntax(reference)) {
                try checkKnown(reference, calling: true)
                callee = self.reference(reference)
            } else if let member = node.calledExpression.as(MemberAccessExprSyntax.self), member.declName.baseName.text == "init",
                      let base = member.base, !base.is(SuperExprSyntax.self), base.as(DeclReferenceExprSyntax.self)?.baseName.text != "self" {
                // `Point.init(x: 1)` is `Point(x: 1)`.
                callee = try expression(base)
            } else if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
                // `3.5.rounded()`: a method of the number, not a unit.
                callee = try self.member(member, called: true)
            } else {
                callee = try expression(node.calledExpression)
            }
        }
        guard node.additionalTrailingClosures.isEmpty else { throw unsupported("more than one trailing closure", node) }
        var arguments = try arguments(node.arguments)
        if let trailing = node.trailingClosure {
            arguments.append(Argument(label: nil, value: .closure(try closure(trailing))))
        }
        if let member = node.calledExpression.as(MemberAccessExprSyntax.self), isCase {
            return .caseLiteral(member.declName.baseName.text, arguments)
        }
        return .call(callee!, arguments)
    }

    /// Where names have to be bound (`strictNames`): a name that isn't is not an
    /// expression, which the layer takes for a command's word.
    mutating func checkKnown(_ node: DeclReferenceExprSyntax, calling: Bool) throws {
        guard strictNames else { return }
        let name = node.baseName.text
        if name == "self" || name == "_" || names()[name] != nil { return }
        failedAt = node.endPositionBeforeTrailingTrivia.utf8Offset
        throw SyntaxError(calling ? "no function named '\(name)'" : "no variable named '\(name)'")
    }

    /// The `x?` a postfix chain starts from, and how many links (members, subscripts, `!`; a call with its method counts once) are after it.
    private func optionalChainCore(_ expr: ExprSyntax) -> (OptionalChainingExprSyntax, Int)? {
        var node = expr
        var depth = 0
        while true {
            if let chained = node.as(OptionalChainingExprSyntax.self) { return (chained, depth) }
            if let member = node.as(MemberAccessExprSyntax.self), let base = member.base { node = base; depth += 1 }
            else if let subscripted = node.as(SubscriptCallExprSyntax.self) { node = subscripted.calledExpression; depth += 1 }
            else if let unwrapped = node.as(ForceUnwrapExprSyntax.self) { node = unwrapped.expression; depth += 1 }
            else if let call = node.as(FunctionCallExprSyntax.self) {
                node = call.calledExpression
                if !node.is(MemberAccessExprSyntax.self) { depth += 1 }
            } else { return nil }
        }
    }

    /// `o?.i.v` as `$chain(o) { $chain1 in $chain1.i.v }`: nil if `o` is, else what the rest gives.
    private mutating func chain(_ expr: ExprSyntax, _ core: OptionalChainingExprSyntax) throws -> Expr {
        chainCount += 1
        let name = "$chain\(chainCount)"
        chainPlaceholders[core.id] = name
        defer { chainPlaceholders[core.id] = nil }
        locals.append([name])
        let rest = try expression(expr)
        locals.removeLast()
        let base = try expression(core.expression)
        let closure = ClosureLiteral(parameters: [Parameter(name: name)], body: Program(statements: [.expression(rest)], lines: [line(of: expr)]),
                                     names: NamesUsed(names: names(in: expr)))
        return .call(.variable("$chain"), [Argument(value: base), Argument(value: .closure(closure))])
    }

    private mutating func subscriptCall(_ node: SubscriptCallExprSyntax) throws -> Expr {
        // The base first, as it is read: a name that isn't bound is found before
        // what is wrong with the subscript.
        let chained = node.calledExpression.as(OptionalChainingExprSyntax.self).flatMap { chainPlaceholders[$0.id] == nil ? $0 : nil }
        let base = try expression(chained?.expression ?? node.calledExpression)
        // `value[keyPath: \.a.b]`: the member it names.
        if node.arguments.count == 1, let argument = node.arguments.first, argument.label?.text == "keyPath",
           let literal = argument.expression.as(KeyPathExprSyntax.self), literal.root == nil {
            guard case .keyPath(_, let path) = try keyPath(literal) else { throw unsupported("this key path", literal) }
            return path.reduce(base) { .member($0, $1) }
        }
        // `counts[word, default: 0]`.
        if node.arguments.count == 2, let key = node.arguments.first, key.label == nil, let fallback = node.arguments.last,
           fallback.label?.text == "default" {
            return .indexDefault(base, try expression(key.expression), try expression(fallback.expression))
        }
        // `xs[2...]`, `xs[..<3]`, `xs[...3]`: what `suffix(from:)`, `prefix(upTo:)` and `prefix(through:)` give.
        if node.arguments.count == 1, let argument = node.arguments.first, argument.label == nil {
            if let partial = argument.expression.as(PostfixOperatorExprSyntax.self), partial.operator.text == "..." {
                return .call(.member(base, "suffix"), [Argument(label: "from", value: try expression(partial.expression))])
            }
            if let partial = argument.expression.as(PrefixOperatorExprSyntax.self), partial.operator.text == "..." || partial.operator.text == "..<" {
                let label = partial.operator.text == "..." ? "through" : "upTo"
                return .call(.member(base, "prefix"), [Argument(label: label, value: try expression(partial.expression))])
            }
        }
        guard node.arguments.count == 1, let argument = node.arguments.first, argument.label == nil else {
            return .subscripted(base, try arguments(node.arguments))
        }
        let index = try expression(argument.expression)
        return chained != nil ? .optionalIndex(base, index) : .index(base, index)
    }

    private mutating func dictionary(_ node: DictionaryExprSyntax) throws -> Expr {
        switch node.content {
        case .colon: return .record([])
        case .elements(let elements):
            return .record(try elements.map { RecordEntry(key: try expression($0.key), value: try expression($0.value)) })
        }
    }

    private mutating func tuple(_ node: TupleExprSyntax) throws -> Expr {
        if node.elements.count == 1, let only = node.elements.first, only.label == nil { return try expression(only.expression) }
        return .tuple(try arguments(node.elements))
    }

    // MARK: Closures and key paths

    mutating func closure(_ node: ClosureExprSyntax) throws -> ClosureLiteral {
        var parameters: [Parameter] = []
        var returnType: TypeAnnotation?
        var captures: [ClosureLiteral.Capture] = []
        if let signature = node.signature {
            guard signature.attributes.isEmpty else { throw unsupported("this closure signature", signature) }
            for item in signature.capture?.items ?? [] {
                let specifier = item.specifier?.specifier.tokenKind
                let isWeak = specifier == .keyword(.weak)
                guard item.specifier == nil || isWeak || specifier == .keyword(.unowned) else { throw unsupported("this capture", item) }
                let name = item.name.text
                let value: Expr
                if let initializer = item.initializer {
                    value = try expression(initializer.value)
                } else {
                    value = reference(DeclReferenceExprSyntax(baseName: item.name))
                }
                captures.append(ClosureLiteral.Capture(name: name, value: value, isWeak: isWeak, isUnowned: specifier == .keyword(.unowned)))
            }
            switch signature.parameterClause {
            case .simpleInput(let names)?:
                parameters = names.map { Parameter(name: $0.name.text) }
            case .parameterClause(let clause)?:
                parameters = try clause.parameters.map { parameter in
                    guard parameter.attributes.isEmpty else { throw unsupported("an attribute on a closure's parameter", parameter) }
                    let name = parameter.secondName?.text ?? parameter.firstName.text
                    return Parameter(name: name, type: try parameter.type.map { try type($0) } ?? .any)
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
        var literal = ClosureLiteral(parameters: parameters, returnType: returnType, body: body, names: NamesUsed(names: names(in: node.statements)))
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

    private mutating func keyPath(_ node: KeyPathExprSyntax) throws -> Expr {
        var path: [String] = []
        for component in node.components {
            guard case .property(let property) = component.component else { throw unsupported("this key path component", component) }
            path.append(property.declName.baseName.text)
        }
        return .keyPath(root: node.root?.trimmedDescription, path: path)
    }

    // MARK: Operators

    private mutating func prefix(_ node: PrefixOperatorExprSyntax) throws -> Expr {
        let operand = try expression(node.expression)
        switch node.operator.text {
        case "-": return .unary(.negate, operand)
        case "!": return .unary(.not, operand)
        case "~": return .unary(.bitNot, operand)
        // A prefix operator the program declares.
        default: return .call(.variable("prefix " + node.operator.text), [Argument(value: operand)])
        }
    }

    private func binaryOperator(_ text: String) -> BinaryOperator? {
        BinaryOperator(rawValue: text)
    }

    /// Whether an operator assigns to its left side, from Swift's rule: `op=`
    /// for an `op`, but not the comparisons that also end in `=` (`==`, `!=`,
    /// `<=`, `>=`, `===`, `!==`).
    static func isCompoundAssignment(_ text: String) -> Bool {
        text.count > 1 && text.hasSuffix("=") && !["==", "!=", "<=", ">=", "===", "!=="].contains(text)
    }

    private mutating func infix(_ node: InfixOperatorExprSyntax) throws -> Expr {
        // Left to right, as it is read: a name that isn't bound is found before an operator that isn't Swish's.
        let left = try expression(node.leftOperand)
        if node.operator.is(AssignmentExprSyntax.self) { throw unsupported("an assignment in an expression", node) }
        guard let op = node.operator.as(BinaryOperatorExprSyntax.self) else {
            throw unsupported("the operator '\(node.operator.trimmedDescription)'", node.operator)
        }
        // An operator the program declares is a function of that name.
        guard let kind = binaryOperator(op.operator.text) else {
            // Identity: a function, and `!==` is its negation.
            if op.operator.text == "===" || op.operator.text == "!==" {
                let identical = Expr.call(.variable("==="), [Argument(value: left), Argument(value: try expression(node.rightOperand))])
                return op.operator.text == "===" ? identical : .unary(.not, identical)
            }
            // Only one a program declares is a function it can call.
            guard names()[op.operator.text] != nil else { throw unsupported("the operator '\(op.operator.text)'", node.operator) }
            return .call(.variable(op.operator.text), [Argument(value: left), Argument(value: try expression(node.rightOperand))])
        }
        return .binary(kind, left, try expression(node.rightOperand))
    }

    private mutating func ternary(_ node: TernaryExprSyntax) throws -> Expr {
        let condition = try expression(node.condition)
        let then = IfStatement.branch(try expression(node.thenExpression))
        let otherwise = IfStatement.branch(try expression(node.elseExpression))
        return .ifExpression(IfStatement(condition: .expression(condition), then: then, otherwise: otherwise))
    }

    /// `x = 1`, `p.x += 1`, `xs[0] = v`: the place and what is done to it.
    mutating func assignment(_ node: InfixOperatorExprSyntax) throws -> Assignment? {
        var op: BinaryOperator?
        if node.operator.is(AssignmentExprSyntax.self) {
            op = nil
        } else if let binary = node.operator.as(BinaryOperatorExprSyntax.self), Lowering.isCompoundAssignment(binary.operator.text) {
            guard let kind = binaryOperator(String(binary.operator.text.dropLast())) else {
                throw unsupported("the operator '\(binary.operator.text)'", binary)
            }
            op = kind
        } else {
            return nil
        }
        return try placeAssignment(node.leftOperand, op: op, value: node.rightOperand, node: node)
    }

    /// `total = 5`, `total += 1` where `total` is a computed variable: its setter.
    mutating func computedAssignment(_ node: InfixOperatorExprSyntax) throws -> [Statement]? {
        guard let target = node.leftOperand.as(DeclReferenceExprSyntax.self), facts.computedGlobals.contains(target.baseName.text),
              !locals.contains(where: { $0.contains(target.baseName.text) }) else { return nil }
        let name = target.baseName.text
        var op: BinaryOperator?
        if node.operator.is(AssignmentExprSyntax.self) {
            op = nil
        } else if let binary = node.operator.as(BinaryOperatorExprSyntax.self), Lowering.isCompoundAssignment(binary.operator.text) {
            op = binaryOperator(String(binary.operator.text.dropLast()))
            guard op != nil else { return nil }
        } else {
            return nil
        }
        var value = try expression(node.rightOperand)
        if let op { value = .binary(op, .call(.variable("$get_" + name), []), value) }
        return [.expression(.call(.variable("$set_" + name), [Argument(value: value)]))]
    }

    /// `x <+>= y` where the program declares `func <+>= (lhs: inout T, rhs: T)`: a call, with `x` passed as `&x`.
    mutating func customCompound(_ node: InfixOperatorExprSyntax) throws -> [Statement]? {
        guard let binary = node.operator.as(BinaryOperatorExprSyntax.self), Lowering.isCompoundAssignment(binary.operator.text),
              binaryOperator(String(binary.operator.text.dropLast())) == nil, names()[binary.operator.text] != nil else { return nil }
        let place = try expression(node.leftOperand)
        return [.expression(.call(.variable(binary.operator.text),
                                  [Argument(value: .inoutArgument(place)), Argument(value: try expression(node.rightOperand))]))]
    }

    /// `(a, b) = (b, a + b)`: the right side held once, and each place given its element.
    mutating func tupleAssignment(_ node: InfixOperatorExprSyntax) throws -> [Statement]? {
        guard node.operator.is(AssignmentExprSyntax.self), let tuple = node.leftOperand.as(TupleExprSyntax.self), tuple.elements.count > 1 else { return nil }
        destructurings += 1
        let held = "$tuple\(destructurings)"
        var statements: [Statement] = [.declare(name: held, mutable: false, value: try expression(node.rightOperand))]
        for (index, element) in tuple.elements.enumerated() {
            if element.expression.is(DiscardAssignmentExprSyntax.self) { continue }
            statements.append(.assign(try placeAssignment(element.expression, op: nil, value: nil, held: .member(.variable(held), "\(index)"), node: element)))
        }
        return statements
    }

    private mutating func placeAssignment(
        _ leftOperand: ExprSyntax, op: BinaryOperator?, value rightOperand: ExprSyntax?, held: Expr? = nil, node: some SyntaxProtocol
    ) throws -> Assignment {
        var path: [Assignment.Step] = []
        var place = leftOperand
        while true {
            if let member = place.as(MemberAccessExprSyntax.self), let base = member.base {
                path.insert(.member(member.declName.baseName.text), at: 0)
                place = base
            } else if let chained = place.as(OptionalChainingExprSyntax.self) {
                path.insert(.optionalChain, at: 0)
                place = chained.expression
            } else if let unwrapped = place.as(ForceUnwrapExprSyntax.self) {
                path.insert(.unwrap, at: 0)
                place = unwrapped.expression
            } else if let subscripted = place.as(SubscriptCallExprSyntax.self), subscripted.arguments.count == 2,
                      let key = subscripted.arguments.first, key.label == nil, let fallback = subscripted.arguments.last,
                      fallback.label?.text == "default" {
                path.insert(.indexDefault(try expression(key.expression), try expression(fallback.expression)), at: 0)
                place = subscripted.calledExpression
            } else if let subscripted = place.as(SubscriptCallExprSyntax.self), subscripted.arguments.count == 1,
                      let argument = subscripted.arguments.first, argument.label == nil {
                path.insert(.index(try expression(argument.expression)), at: 0)
                place = subscripted.calledExpression
            } else if let subscripted = place.as(SubscriptCallExprSyntax.self) {
                path.insert(.subscripted(try arguments(subscripted.arguments)), at: 0)
                place = subscripted.calledExpression
            } else {
                break
            }
        }
        guard let root = place.as(DeclReferenceExprSyntax.self) else { throw unsupported("this assignment", leftOperand) }
        var rootName = root.baseName.text
        // A static member, in a static member: `made += 1` is `Counter.made += 1`.
        if !locals.contains(where: { $0.contains(rootName) }), let context = staticContext, context.names.contains(rootName) {
            path.insert(.member(rootName), at: 0)
            rootName = context.owner
        }
        // A struct's own member, in a method: `n += 1` is `self.n += 1`.
        else if !locals.contains(where: { $0.contains(rootName) }), members.last?.contains(rootName) == true {
            path.insert(.member(rootName), at: 0)
            rootName = "self"
        }
        return Assignment(root: rootName, path: path, op: op, value: try held ?? expression(rightOperand!))
    }
}

/// The highest `$n` in a closure's body, not looking into closures nested in it.
private final class AnonymousArity: SyntaxVisitor {
    var highest = -1
    init() { super.init(viewMode: .sourceAccurate) }
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        let name = node.baseName.text
        if name.hasPrefix("$"), let index = Int(name.dropFirst()) { highest = max(highest, index) }
        return .visitChildren
    }
}
