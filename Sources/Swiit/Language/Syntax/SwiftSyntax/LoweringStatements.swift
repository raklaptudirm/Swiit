import SwiftSyntax
import SwiitKit

extension Lowering {
    // MARK: Statements

    mutating func statement(_ item: CodeBlockItemSyntax.Item) throws -> [Statement] {
        switch item {
        case .decl(let decl): return try declaration(decl)
        case .stmt(let stmt):
            if let node = stmt.as(GuardStmtSyntax.self) { return try guardStatements(node) }
            return [try statementNode(stmt)]
        case .expr(let expr):
            if let node = expr.as(InfixOperatorExprSyntax.self) {
                if let statements = try tupleAssignment(node) { return statements }
                if let statements = try computedAssignment(node) { return statements }
                if let statements = try customCompound(node) { return statements }
            }
            return [try expressionStatement(expr)]
        }
    }

    private mutating func expressionStatement(_ expr: ExprSyntax) throws -> Statement {
        if let node = expr.as(IfExprSyntax.self) {
            return .ifStatement(try ifStatement(node))
        }
        if let node = expr.as(SwitchExprSyntax.self) {
            return .switchStatement(try switchStatement(node))
        }
        if let node = expr.as(InfixOperatorExprSyntax.self), let pipeline = try valuePipeline(node) {
            return .expression(pipeline)
        }
        // `_ = f()`: the value, thrown away, as `let _ = f()` does.
        if let node = expr.as(InfixOperatorExprSyntax.self), node.operator.is(AssignmentExprSyntax.self),
           node.leftOperand.is(DiscardAssignmentExprSyntax.self) {
            return .declare(name: "_", mutable: false, value: try expression(node.rightOperand))
        }
        if let node = expr.as(InfixOperatorExprSyntax.self), let assignment = try assignment(node) {
            return .assign(assignment)
        }
        return .expression(try expression(expr))
    }

    private mutating func statementNode(_ stmt: StmtSyntax) throws -> Statement {
        if let node = stmt.as(ExpressionStmtSyntax.self) { return try expressionStatement(node.expression) }
        if let node = stmt.as(ThrowStmtSyntax.self) { return .throwStatement(try expression(node.expression)) }
        if let node = stmt.as(ReturnStmtSyntax.self) {
            guard leaving.function > 0 else { throw SyntaxError("'return' outside a function (line \(line(of: node)))") }
            return .returnStatement(try node.expression.map { try expression($0) })
        }
        if let node = stmt.as(BreakStmtSyntax.self) {
            if let label = node.label {
                guard leaving.labels.contains(label.text) else { throw SyntaxError("use of unresolved label '\(label.text)' (line \(line(of: node)))") }
                return .breakStatement(label: label.text)
            }
            guard leaving.loop > 0 || leaving.switchCase > 0 else { throw SyntaxError("'break' outside a loop or switch (line \(line(of: node)))") }
            return .breakStatement()
        }
        if let node = stmt.as(ContinueStmtSyntax.self) {
            if let label = node.label {
                guard leaving.labels.contains(label.text) else { throw SyntaxError("use of unresolved label '\(label.text)' (line \(line(of: node)))") }
                return .continueStatement(label: label.text)
            }
            guard leaving.loop > 0 else { throw SyntaxError("'continue' outside a loop (line \(line(of: node)))") }
            return .continueStatement()
        }
        if stmt.is(FallThroughStmtSyntax.self) {
            guard leaving.switchCase > 0 else { throw SyntaxError("'fallthrough' outside a switch (line \(line(of: stmt)))") }
            return .fallthroughStatement
        }
        if let node = stmt.as(DeferStmtSyntax.self) {
            // Nothing leaves a `defer`: it can't return, break or continue.
            let outer = leaving
            leaving = Leaving()
            defer { leaving = outer }
            return .deferBlock(try block(node.body.statements))
        }
        if let node = stmt.as(LabeledStmtSyntax.self) { return try labeled(node) }
        if let node = stmt.as(WhileStmtSyntax.self) { return try whileLoop(node) }
        if let node = stmt.as(RepeatStmtSyntax.self) { return try repeatLoop(node) }
        if let node = stmt.as(ForStmtSyntax.self) { return .forLoop(try forLoop(node)) }
        if let node = stmt.as(DoStmtSyntax.self) { return try doCatch(node) }
        throw unsupported("'\(stmt.kind)'", stmt)
    }

    // MARK: Conditions and loops

    /// `guard a, let b else { … }`: one guard for each condition, each with the same `else`.
    private mutating func guardStatements(_ node: GuardStmtSyntax) throws -> [Statement] {
        let conditions = try conditionList(node.conditions, isGuard: true)
        let otherwise = try block(node.body.statements)
        return conditions.map { .guardStatement($0, otherwise: otherwise) }
    }

    /// Every condition of an `if`, `guard` or `while`, each seeing what the ones before it bind.
    mutating func conditionList(_ list: ConditionElementListSyntax, isGuard: Bool = false) throws -> [IfStatement.Condition] {
        try list.map { try condition(element: $0, isGuard: isGuard) }
    }

    mutating func condition(_ conditions: ConditionElementListSyntax, _ node: some SyntaxProtocol, isGuard: Bool = false) throws -> IfStatement.Condition {
        guard conditions.count == 1, let element = conditions.first else { throw unsupported("more than one condition", node) }
        return try condition(element: element, isGuard: isGuard)
    }

    mutating func condition(element: ConditionElementSyntax, isGuard: Bool = false) throws -> IfStatement.Condition {
        switch element.condition {
        case .expression(let expr):
            // A command as a condition (`if grep -q x f { … }`), read by the layer.
            if let island = try layerCondition(at: element.positionAfterSkippingLeadingTrivia.utf8Offset, isGuard: isGuard) {
                return .expression(island.condition)
            }
            return .expression(try expression(expr))
        case .optionalBinding(let binding):
            guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else { throw unsupported("this binding", binding) }
            let lowered: Expr
            if let value = binding.initializer?.value {
                lowered = try expression(value)
            } else {
                // `if let x`, `guard let x`: shorthand for `x = x`.
                let reference = DeclReferenceExprSyntax(baseName: identifier.identifier)
                try checkKnown(reference, calling: false)
                lowered = self.reference(reference)
            }
            bind(identifier.identifier.text)
            return .binding(name: identifier.identifier.text, mutable: binding.bindingSpecifier.tokenKind == .keyword(.var), value: lowered)
        case .matchingPattern(let matching):
            let subject = try expression(matching.initializer.value)
            return .pattern(try pattern(matching.pattern), subject)
        default:
            throw unsupported("this condition", element)
        }
    }

    mutating func ifStatement(_ node: IfExprSyntax) throws -> IfStatement {
        // What the conditions bind is visible in the first branch only.
        locals.append([])
        let conditions = try conditionList(node.conditions)
        let then = try block(node.body.statements)
        locals.removeLast()
        var otherwise: Program?
        switch node.elseBody {
        case nil: otherwise = nil
        case .codeBlock(let code)?: otherwise = try block(code.statements)
        case .ifExpr(let nested)?:
            otherwise = Program(statements: [.ifStatement(try ifStatement(nested))])
        }
        // `if a, let b { … } else { … }` is `if a { if let b { … } else { … } } else { … }`.
        var result = IfStatement(condition: conditions[conditions.count - 1], then: then, otherwise: otherwise)
        for condition in conditions.dropLast().reversed() {
            result = IfStatement(condition: condition, then: Program(statements: [.ifStatement(result)], lines: [line(of: node)]), otherwise: otherwise)
        }
        return result
    }

    /// `outer: for …`, `outer: while …`: a loop `break outer` and `continue outer` name.
    private mutating func labeled(_ node: LabeledStmtSyntax) throws -> Statement {
        let label = node.label.text
        if let loop = node.statement.as(ForStmtSyntax.self) { return .forLoop(try forLoop(loop, label: label)) }
        if let loop = node.statement.as(WhileStmtSyntax.self) { return try whileLoop(loop, label: label) }
        if let loop = node.statement.as(RepeatStmtSyntax.self) { return try repeatLoop(loop, label: label) }
        throw unsupported("a label on anything but a loop", node)
    }

    private mutating func whileLoop(_ node: WhileStmtSyntax, label: String? = nil) throws -> Statement {
        // What a condition binds is visible in the body only.
        locals.append([])
        defer { locals.removeLast() }
        let conditions = try conditionList(node.conditions)
        leaving.loop += 1
        if let label { leaving.labels.append(label) }
        defer { leaving.loop -= 1; if label != nil { leaving.labels.removeLast() } }
        var body = try block(node.body.statements)
        let tests = conditions.compactMap { condition -> Expr? in if case .expression(let test) = condition { test } else { nil } }
        if tests.count == conditions.count, let first = tests.first {
            return .whileLoop(WhileLoop(condition: tests.dropFirst().reduce(first) { .binary(.and, $0, $1) }, body: body, label: label))
        }
        // `while let x = next() { … }` is `while true { guard let x = next() else { break }; … }`.
        let first = body.lines.first ?? line(of: node)
        let leave = Program(statements: [.breakStatement()], lines: [first])
        body.statements.insert(contentsOf: conditions.map { .guardStatement($0, otherwise: leave) }, at: 0)
        if !body.lines.isEmpty { body.lines.insert(contentsOf: conditions.map { _ in first }, at: 0) }
        return .whileLoop(WhileLoop(condition: .literal(.bool(true)), body: body, label: label))
    }

    private mutating func repeatLoop(_ node: RepeatStmtSyntax, label: String? = nil) throws -> Statement {
        leaving.loop += 1
        if let label { leaving.labels.append(label) }
        let body: Program
        do {
            body = try block(node.body.statements)
            leaving.loop -= 1
            if label != nil { leaving.labels.removeLast() }
        } catch {
            leaving.loop -= 1
            if label != nil { leaving.labels.removeLast() }
            throw error
        }
        return .whileLoop(WhileLoop(condition: try expression(node.condition), body: body, isRepeat: true, label: label))
    }

    private mutating func forLoop(_ node: ForStmtSyntax, label: String? = nil) throws -> ForLoop {
        // A name, `_`, or a tuple of them: `for (i, x) in …`.
        let bound = locals
        let pattern = try self.pattern(node.pattern, mutable: false)
        locals = bound
        let sequence = try expression(node.sequence)
        locals.append(Set(SwitchBinding.names(boundBy: pattern)))
        leaving.loop += 1
        if let label { leaving.labels.append(label) }
        defer { locals.removeLast(); leaving.loop -= 1; if label != nil { leaving.labels.removeLast() } }
        var body = try block(node.body.statements, scoped: false)
        // `for x in xs where c { … }`: the body runs for the items `c` holds for.
        if let clause = node.whereClause {
            let condition = try expression(clause.condition)
            body = Program(statements: [.ifStatement(IfStatement(condition: .expression(condition), then: body))], lines: [line(of: clause)])
        }
        // `for case let x? in xs`: the body runs for the items that match the pattern.
        if node.caseKeyword != nil {
            body = Program(statements: [.ifStatement(IfStatement(condition: .pattern(pattern, .variable(InternalName.item)), then: body))], lines: [line(of: node)])
            return ForLoop(pattern: .binding(name: InternalName.item, mutable: false), sequence: sequence, body: body,
                           isAwait: node.awaitKeyword != nil, isTry: node.tryKeyword != nil, label: label)
        }
        return ForLoop(pattern: pattern, sequence: sequence, body: body,
                       isAwait: node.awaitKeyword != nil, isTry: node.tryKeyword != nil, label: label)
    }

    private mutating func doCatch(_ node: DoStmtSyntax) throws -> Statement {
        let body = try block(node.body.statements)
        var clauses: [SwitchCase] = []
        for clause in node.catchClauses {
            guard clause.catchItems.count <= 1 else { throw unsupported("a 'catch' of several patterns", clause) }
            locals.append([])
            defer { locals.removeLast() }
            guard let item = clause.catchItems.first else {
                bind("error")
                clauses.append(SwitchCase(patterns: [], body: try block(clause.body.statements, scoped: false)))
                continue
            }
            guard let syntax = item.pattern else { throw unsupported("this 'catch'", clause) }
            let caught = try pattern(syntax)
            let guardExpr = try item.whereClause.map { try expression($0.condition) }
            clauses.append(SwitchCase(patterns: [caught], guardExpr: guardExpr, body: try block(clause.body.statements, scoped: false)))
        }
        return .doCatch(body: body, clauses: clauses)
    }

    // MARK: Switch and patterns

    mutating func switchStatement(_ node: SwitchExprSyntax) throws -> SwitchStatement {
        let subject = try expression(node.subject)
        var cases: [SwitchCase] = []
        leaving.switchCase += 1
        defer { leaving.switchCase -= 1 }
        for element in node.cases {
            guard case .switchCase(let switchCase) = element else { throw unsupported("a compiler directive in a 'switch'", element) }
            locals.append([])
            defer { locals.removeLast() }
            var patterns: [Pattern] = []
            var guardExpr: ExprSyntax?
            switch switchCase.label {
            case .default:
                break
            case .case(let label):
                for (position, item) in label.caseItems.enumerated() {
                    patterns.append(try pattern(item.pattern))
                    guard let clause = item.whereClause else { continue }
                    // A case holds one guard, the last pattern's.
                    guard position == label.caseItems.count - 1 else {
                        throw unsupported("a 'where' on a case's pattern other than its last", clause)
                    }
                    guardExpr = clause.condition
                }
            }
            let lowered = try guardExpr.map { try expression($0) }
            // Every pattern of a case binds the same names, for the body to use.
            let bound = patterns.map { Set(SwitchBinding.names(boundBy: $0)) }
            if let first = bound.first, !bound.allSatisfy({ $0 == first }) {
                throw SyntaxError("each pattern in a case must bind the same names (line \(line(of: switchCase)))")
            }
            guard !switchCase.statements.isEmpty else {
                throw SyntaxError("a case needs at least one statement; write `break` to do nothing (line \(line(of: switchCase)))")
            }
            cases.append(SwitchCase(patterns: patterns, guardExpr: lowered, body: try block(switchCase.statements, scoped: false)))
        }
        return SwitchStatement(subject: subject, cases: cases)
    }

    mutating func pattern(_ pattern: PatternSyntax, mutable: Bool? = nil) throws -> Pattern {
        if pattern.is(WildcardPatternSyntax.self) { return .wildcard }
        // `(a, _)`, `let (a, b)`.
        if let node = pattern.as(TuplePatternSyntax.self) {
            guard node.elements.allSatisfy({ $0.label == nil }) else { throw unsupported("a label in a tuple pattern", node) }
            return .tuple(try node.elements.map { try self.pattern($0.pattern, mutable: mutable) })
        }
        // `is Oops`.
        if let node = pattern.as(IsTypePatternSyntax.self) { return .isType(try type(node.type)) }
        // `x` under `let`: what it binds.
        if let mutable, let identifier = pattern.as(IdentifierPatternSyntax.self) {
            bind(identifier.identifier.text)
            return .binding(name: identifier.identifier.text, mutable: mutable)
        }
        if let binding = pattern.as(ValueBindingPatternSyntax.self) {
            return try self.pattern(binding.pattern, mutable: binding.bindingSpecifier.tokenKind == .keyword(.var))
        }
        // `let e as Oops`, `_ as Int`.
        if let node = pattern.as(ExpressionPatternSyntax.self), let cast = node.expression.as(AsExprSyntax.self),
           cast.questionOrExclamationMark == nil {
            return .cast(try castOperand(cast.expression, mutable: mutable), try type(cast.type))
        }
        if let node = pattern.as(ExpressionPatternSyntax.self) { return try expressionPattern(node.expression, mutable: mutable) }
        throw unsupported("the pattern '\(pattern.kind)'", pattern)
    }

    /// `.failed(code: let c)`, `Result.failed`, `.a`, or a value to compare with.
    private mutating func expressionPattern(_ expr: ExprSyntax, mutable: Bool? = nil) throws -> Pattern {
        // `let x?`: what isn't nil.
        if let node = expr.as(OptionalChainingExprSyntax.self) { return .some(try argumentPattern(node.expression, mutable: mutable)) }
        // `5...`, `..<3`, `...9`.
        if let node = expr.as(PostfixOperatorExprSyntax.self), node.operator.text == "..." {
            return .partialRange(lower: try expression(node.expression), upper: nil, closed: true)
        }
        if let node = expr.as(PrefixOperatorExprSyntax.self), node.operator.text == "..." || node.operator.text == "..<" {
            return .partialRange(lower: nil, upper: try expression(node.expression), closed: node.operator.text == "...")
        }
        // `(1, _)`: a tuple, element by element. One in parentheses is its element.
        if let tuple = expr.as(TupleExprSyntax.self), tuple.elements.count != 1 {
            guard tuple.elements.allSatisfy({ $0.label == nil }) else { throw unsupported("a label in a tuple pattern", tuple) }
            return .tuple(try tuple.elements.map { try argumentPattern($0.expression, mutable: mutable) })
        }
        if let call = expr.as(FunctionCallExprSyntax.self), let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
            var arguments: [PatternArgument] = []
            for argument in call.arguments {
                arguments.append(PatternArgument(label: argument.label?.text, pattern: try argumentPattern(argument.expression, mutable: mutable)))
            }
            return .enumCase(type: member.base.map { $0.trimmedDescription }, name: member.declName.baseName.text, arguments: arguments)
        }
        if let member = expr.as(MemberAccessExprSyntax.self), isCaseReference(member) {
            return .enumCase(type: member.base.map { $0.trimmedDescription }, name: member.declName.baseName.text, arguments: nil)
        }
        return .expression(try expression(expr))
    }

    /// What a cast pattern casts: `e` under `let`, `_`, or another pattern.
    private mutating func castOperand(_ expr: ExprSyntax, mutable: Bool?) throws -> Pattern {
        if let binding = expr.as(PatternExprSyntax.self) { return try pattern(binding.pattern, mutable: mutable) }
        if expr.is(DiscardAssignmentExprSyntax.self) { return .wildcard }
        if let mutable, let reference = expr.as(DeclReferenceExprSyntax.self) {
            bind(reference.baseName.text)
            return .binding(name: reference.baseName.text, mutable: mutable)
        }
        return try expressionPattern(expr, mutable: mutable)
    }

    /// An argument of a case pattern: under `let`, a name is a binding, as in `case let .c(m)`.
    private mutating func argumentPattern(_ expr: ExprSyntax, mutable: Bool? = nil) throws -> Pattern {
        if let binding = expr.as(PatternExprSyntax.self) { return try pattern(binding.pattern, mutable: mutable) }
        if expr.is(DiscardAssignmentExprSyntax.self) { return .wildcard }
        if let mutable, let reference = expr.as(DeclReferenceExprSyntax.self) {
            bind(reference.baseName.text)
            return .binding(name: reference.baseName.text, mutable: mutable)
        }
        return try expressionPattern(expr, mutable: mutable)
    }

    /// `.a` or `E.a` in a pattern: a case, since a value would be written with its type's name.
    private func isCaseReference(_ member: MemberAccessExprSyntax) -> Bool {
        guard let base = member.base else { return true }
        guard let reference = base.as(DeclReferenceExprSyntax.self) else { return false }
        return declaredTypes.contains(reference.baseName.text) || bound[reference.baseName.text] == .type
    }

    mutating func bind(_ name: String) {
        locals[locals.count - 1].insert(name)
    }
}

/// The names a pattern binds.
enum SwitchBinding {
    static func names(boundBy pattern: Pattern) -> [String] {
        switch pattern {
        case .binding(let name, _): [name]
        case .enumCase(_, _, let arguments): (arguments ?? []).flatMap { names(boundBy: $0.pattern) }
        case .cast(let inner, _): names(boundBy: inner)
        case .tuple(let patterns): patterns.flatMap { names(boundBy: $0) }
        case .some(let inner): names(boundBy: inner)
        case .wildcard, .expression, .isType, .partialRange: []
        }
    }
}
