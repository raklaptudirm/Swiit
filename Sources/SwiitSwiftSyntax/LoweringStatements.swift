@_spi(Layer) @_spi(Swiit) import Swiit
import SwiftSyntax
import SwiitKit

extension Lowering {
    // MARK: Statements

    mutating func statement(_ item: CodeBlockItemSyntax.Item) throws -> [Statement] {
        switch item {
        case .decl(let decl): return try declaration(decl)
        case .stmt(let stmt): return [try statementNode(stmt)]
        case .expr(let expr): return [try expressionStatement(expr)]
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
            guard node.label == nil else { throw unsupported("a labeled break", node) }
            guard leaving.loop > 0 || leaving.switchCase > 0 else { throw SyntaxError("'break' outside a loop or switch (line \(line(of: node)))") }
            return .breakStatement
        }
        if let node = stmt.as(ContinueStmtSyntax.self) {
            guard node.label == nil else { throw unsupported("a labeled continue", node) }
            guard leaving.loop > 0 else { throw SyntaxError("'continue' outside a loop (line \(line(of: node)))") }
            return .continueStatement
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
        if let node = stmt.as(GuardStmtSyntax.self) {
            let condition = try condition(node.conditions, node, isGuard: true)
            return .guardStatement(condition, otherwise: try block(node.body.statements))
        }
        if let node = stmt.as(WhileStmtSyntax.self) {
            let condition = try condition(node.conditions, node)
            guard case .expression(let test) = condition else { throw unsupported("a binding in a 'while'", node) }
            leaving.loop += 1
            defer { leaving.loop -= 1 }
            return .whileLoop(WhileLoop(condition: test, body: try block(node.body.statements)))
        }
        if let node = stmt.as(ForStmtSyntax.self) { return .forLoop(try forLoop(node)) }
        if let node = stmt.as(DoStmtSyntax.self) { return try doCatch(node) }
        throw unsupported("'\(stmt.kind)'", stmt)
    }

    // MARK: Conditions and loops

    mutating func condition(_ conditions: ConditionElementListSyntax, _ node: some SyntaxProtocol, isGuard: Bool = false) throws -> IfStatement.Condition {
        guard conditions.count == 1, let element = conditions.first else { throw unsupported("more than one condition", node) }
        switch element.condition {
        case .expression(let expr):
            // A command as a condition (`if grep -q x f { … }`), read by the layer.
            if let island = try layerCondition(at: element.positionAfterSkippingLeadingTrivia.utf8Offset, isGuard: isGuard) {
                return .expression(island.condition)
            }
            return .expression(try expression(expr))
        case .optionalBinding(let binding):
            guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self), let value = binding.initializer?.value else {
                throw unsupported("this binding", binding)
            }
            let lowered = try expression(value)
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
        // What the condition binds is visible in the first branch only.
        locals.append([])
        let condition = try condition(node.conditions, node)
        let then = try block(node.body.statements)
        locals.removeLast()
        var otherwise: Program?
        switch node.elseBody {
        case nil: otherwise = nil
        case .codeBlock(let code)?: otherwise = try block(code.statements)
        case .ifExpr(let nested)?:
            otherwise = Program(statements: [.ifStatement(try ifStatement(nested))])
        }
        return IfStatement(condition: condition, then: then, otherwise: otherwise)
    }

    private mutating func forLoop(_ node: ForStmtSyntax) throws -> ForLoop {
        guard node.whereClause == nil else { throw unsupported("this 'for'", node) }
        let variable: String
        if let identifier = node.pattern.as(IdentifierPatternSyntax.self) { variable = identifier.identifier.text }
        else if node.pattern.is(WildcardPatternSyntax.self) { variable = "_" }
        else { throw unsupported("this pattern in a 'for'", node.pattern) }
        let sequence = try expression(node.sequence)
        locals.append([variable])
        leaving.loop += 1
        defer { locals.removeLast(); leaving.loop -= 1 }
        return ForLoop(variable: variable, sequence: sequence, body: try block(node.body.statements, scoped: false),
                       isAwait: node.awaitKeyword != nil, isTry: node.tryKeyword != nil)
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
                for item in label.caseItems {
                    patterns.append(try pattern(item.pattern))
                    if let clause = item.whereClause { guardExpr = clause.condition }
                }
            }
            let lowered = try guardExpr.map { try expression($0) }
            cases.append(SwitchCase(patterns: patterns, guardExpr: lowered, body: try block(switchCase.statements, scoped: false)))
        }
        return SwitchStatement(subject: subject, cases: cases)
    }

    mutating func pattern(_ pattern: PatternSyntax, mutable: Bool? = nil) throws -> Pattern {
        if pattern.is(WildcardPatternSyntax.self) { return .wildcard }
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
        if let node = pattern.as(ExpressionPatternSyntax.self) { return try expressionPattern(node.expression) }
        throw unsupported("this pattern", pattern)
    }

    /// `.failed(code: let c)`, `Result.failed`, `.a`, or a value to compare with.
    private mutating func expressionPattern(_ expr: ExprSyntax) throws -> Pattern {
        if let call = expr.as(FunctionCallExprSyntax.self), let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
            var arguments: [PatternArgument] = []
            for argument in call.arguments {
                arguments.append(PatternArgument(label: argument.label?.text, pattern: try argumentPattern(argument.expression)))
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
        return try expressionPattern(expr)
    }

    private mutating func argumentPattern(_ expr: ExprSyntax) throws -> Pattern {
        if let binding = expr.as(PatternExprSyntax.self) { return try pattern(binding.pattern) }
        if expr.is(DiscardAssignmentExprSyntax.self) { return .wildcard }
        return try expressionPattern(expr)
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
