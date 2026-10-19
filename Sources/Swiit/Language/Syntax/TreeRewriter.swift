import Foundation

/// Rewrites a tree bottom-up: every child is rewritten before its parent is
/// offered to `expr`, which returns what stands in its place (the same node,
/// if there is nothing to do). A layer over the core
/// that adds its own nodes (the shell's, held opaquely in `.extended`) sees
/// them here and rewrites what is inside them itself, with `program`,
/// `expression` and the rest. This is how the shell's constructs become Swift
/// (Swish's Docs/Design/desugaring.md).
@_spi(Layer) public struct TreeRewriter {
    @_spi(Layer) public var expr: (Expr) -> Expr

    @_spi(Layer) public init(expr: @escaping (Expr) -> Expr = { $0 }) {
        self.expr = expr
    }

    // MARK: Programs and statements

    @_spi(Layer) public func program(_ program: Program) -> Program {
        Program(statements: program.statements.map(self.statementNode), lines: program.lines, ranges: program.ranges, spots: program.spots)
    }

    private func block(_ program: Program?) -> Program? { program.map(self.program) }

    func statementNode(_ node: Statement) -> Statement {
        let rewritten: Statement
        switch node {
        case .declare(let name, let mutable, let value):
            rewritten = .declare(name: name, mutable: mutable, value: expression(value))
        case .assign(var assignment):
            assignment.path = assignment.path.map { step in
                switch step {
                case .index(let index): .index(expression(index))
                case .indexDefault(let key, let fallback): .indexDefault(expression(key), expression(fallback))
                case .subscripted(let list): .subscripted(arguments(list))
                case .member, .unwrap, .optionalChain: step
                }
            }
            assignment.value = expression(assignment.value)
            rewritten = .assign(assignment)
        case .function(let decl):
            rewritten = .function(function(decl))
        case .doCatch(let body, let clauses):
            rewritten = .doCatch(body: program(body), clauses: clauses.map { clause in
                SwitchCase(patterns: clause.patterns.map(pattern), guardExpr: clause.guardExpr.map(expression), body: program(clause.body))
            })
        case .throwStatement(let value):
            rewritten = .throwStatement(expression(value))
        case .enumDecl(var decl):
            decl.cases = decl.cases.map { enumCase in
                var copy = enumCase
                copy.rawValue = enumCase.rawValue.map(expression)
                return copy
            }
            decl.properties = decl.properties.map(property)
            decl.staticProperties = decl.staticProperties.map(property)
            decl.methods = decl.methods.map(function)
            decl.staticMethods = decl.staticMethods.map(function)
            decl.initializers = decl.initializers.map(function)
            rewritten = .enumDecl(decl)
        case .structDecl(let decl):
            rewritten = .structDecl(members(decl))
        case .operatorDeclaration, .protocolDecl:
            rewritten = node
        case .classDecl(var decl):
            decl.members = members(decl.members)
            decl.deinitializer = block(decl.deinitializer)
            rewritten = .classDecl(decl)
        case .typeExtension(var decl):
            decl.members = members(decl.members)
            rewritten = .typeExtension(decl)
        case .extensionDecl(let name, let methods):
            rewritten = .extensionDecl(name: name, methods: methods.map(function))
        case .deferBlock(let body):
            rewritten = .deferBlock(program(body))
        case .fallthroughStatement, .breakStatement, .continueStatement:
            rewritten = node
        case .returnStatement(let value):
            rewritten = .returnStatement(value.map(expression))
        case .guardStatement(let condition, let otherwise):
            rewritten = .guardStatement(self.condition(condition), otherwise: program(otherwise))
        case .expression(let value):
            rewritten = .expression(expression(value))
        case .ifStatement(let node):
            rewritten = .ifStatement(ifStatement(node))
        case .switchStatement(let node):
            rewritten = .switchStatement(SwitchStatement(
                subject: expression(node.subject),
                cases: node.cases.map { switchCase in
                    SwitchCase(
                        patterns: switchCase.patterns.map(pattern), guardExpr: switchCase.guardExpr.map(expression),
                        body: program(switchCase.body)
                    )
                }
            ))
        case .forLoop(let loop):
            var copy = loop
            copy.sequence = expression(loop.sequence)
            copy.pattern = pattern(loop.pattern)
            copy.body = program(loop.body)
            rewritten = .forLoop(copy)
        case .whileLoop(let loop):
            var copy = loop
            copy.condition = expression(loop.condition)
            copy.body = program(loop.body)
            rewritten = .whileLoop(copy)
        }
        return rewritten
    }

    func function(_ decl: FunctionDecl) -> FunctionDecl {
        var copy = decl
        copy.parameters = decl.parameters.map(parameter)
        copy.body = program(decl.body)
        return copy
    }

    func parameter(_ parameter: Parameter) -> Parameter {
        var copy = parameter
        copy.defaultValue = parameter.defaultValue.map(expression)
        return copy
    }

    private func property(_ decl: PropertyDecl) -> PropertyDecl {
        var copy = decl
        copy.defaultValue = decl.defaultValue.map(expression)
        copy.getter = block(decl.getter)
        copy.setter = block(decl.setter)
        copy.willSet = block(decl.willSet)
        copy.didSet = block(decl.didSet)
        return copy
    }

    private func members(_ decl: StructDecl) -> StructDecl {
        var copy = decl
        copy.properties = decl.properties.map(property)
        copy.staticProperties = decl.staticProperties.map(property)
        copy.methods = decl.methods.map(function)
        copy.staticMethods = decl.staticMethods.map(function)
        copy.initializers = decl.initializers.map(function)
        copy.subscripts = decl.subscripts.map { declared in
            var changed = declared
            changed.getter = program(declared.getter)
            changed.setter = block(declared.setter)
            return changed
        }
        return copy
    }

    // MARK: Conditions and patterns

    func ifStatement(_ node: IfStatement) -> IfStatement {
        IfStatement(condition: condition(node.condition), then: program(node.then), otherwise: block(node.otherwise))
    }

    private func condition(_ condition: IfStatement.Condition) -> IfStatement.Condition {
        switch condition {
        case .expression(let value): .expression(expression(value))
        case .binding(let name, let mutable, let value): .binding(name: name, mutable: mutable, value: expression(value))
        case .pattern(let value, let subject): .pattern(pattern(value), expression(subject))
        }
    }

    private func pattern(_ value: Pattern) -> Pattern {
        switch value {
        case .wildcard, .binding: value
        case .enumCase(let type, let name, let arguments):
            .enumCase(type: type, name: name, arguments: arguments.map { arguments in
                arguments.map { PatternArgument(label: $0.label, pattern: pattern($0.pattern)) }
            })
        case .expression(let inner): .expression(expression(inner))
        case .cast(let inner, let type): .cast(pattern(inner), type)
        case .isType: value
        case .some(let inner): .some(pattern(inner))
        case .tuple(let patterns): .tuple(patterns.map(pattern))
        case .partialRange(let lower, let upper, let closed): .partialRange(lower: lower.map(expression), upper: upper.map(expression), closed: closed)
        }
    }

    // MARK: Expressions

    @_spi(Layer) public func arguments(_ arguments: [Argument]) -> [Argument] {
        arguments.map { Argument(label: $0.label, value: expression($0.value)) }
    }

    @_spi(Layer) public func closure(_ closure: ClosureLiteral) -> ClosureLiteral {
        var copy = closure
        copy.parameters = closure.parameters.map(parameter)
        copy.body = program(closure.body)
        copy.captures = closure.captures.map { ClosureLiteral.Capture(name: $0.name, value: expression($0.value), isWeak: $0.isWeak, isUnowned: $0.isUnowned) }
        return copy
    }

    @_spi(Layer) public func expression(_ node: Expr) -> Expr {
        let rewritten: Expr
        switch node {
        case .literal, .variable, .filePath:
            rewritten = node
        case .string(let parts):
            rewritten = .string(parts.map { part in
                if case .expression(let inner) = part { .expression(expression(inner)) } else { part }
            })
        case .attempt(let inner, let kind):
            rewritten = .attempt(expression(inner), kind)
        case .await(let target, let throwing):
            rewritten = .await(target.map(expression), throwing: throwing)
        case .list(let items):
            rewritten = .list(items.map(expression))
        case .record(let entries):
            rewritten = .record(entries.map { RecordEntry(key: expression($0.key), value: expression($0.value)) })
        case .closure(let literal):
            rewritten = .closure(closure(literal))
        case .childTask(let literal):
            rewritten = .childTask(closure(literal))
        case .call(let callee, let args):
            rewritten = .call(expression(callee), arguments(args))
        case .member(let base, let name):
            rewritten = .member(expression(base), name)
        case .caseLiteral(let name, let args):
            rewritten = .caseLiteral(name, args.map(arguments))
        case .unary(let op, let inner):
            rewritten = .unary(op, expression(inner))
        case .binary(let op, let lhs, let rhs):
            rewritten = .binary(op, expression(lhs), expression(rhs))
        case .index(let base, let index):
            rewritten = .index(expression(base), expression(index))
        case .indexDefault(let base, let key, let fallback):
            rewritten = .indexDefault(expression(base), expression(key), expression(fallback))
        case .subscripted(let base, let list):
            rewritten = .subscripted(expression(base), arguments(list))
        case .tuple(let elements):
            rewritten = .tuple(arguments(elements))
        case .annotated(let inner, let type):
            rewritten = .annotated(expression(inner), type)
        case .forceUnwrap(let inner):
            rewritten = .forceUnwrap(expression(inner))
        case .optionalMember(let base, let name):
            rewritten = .optionalMember(expression(base), name)
        case .optionalIndex(let base, let index):
            rewritten = .optionalIndex(expression(base), expression(index))
        case .chosen(let inner, let overload):
            rewritten = .chosen(expression(inner), overload: overload)
        case .specialized(let inner, let arguments):
            rewritten = .specialized(expression(inner), arguments)
        case .bridged(let type, let member, let receiver, let args):
            rewritten = .bridged(type: type, member: member, receiver: receiver.map(expression), arguments: arguments(args))
        case .cast(let inner, let type, let kind):
            rewritten = .cast(expression(inner), type, kind)
        case .ifExpression(let node):
            rewritten = .ifExpression(ifStatement(node))
        case .keyPath:
            rewritten = node
        case .voidValue(let inner):
            rewritten = .voidValue(expression(inner))
        case .inoutArgument(let inner):
            rewritten = .inoutArgument(expression(inner))
        case .described(let inner, let type):
            rewritten = .described(expression(inner), type)
        }
        return expr(rewritten)
    }
}
