import Foundation
import SwishKit

/// Rewrites a tree bottom-up: every child is rewritten before its parent is
/// offered to `expr`, `unit` or `statement`, which return what stands in its
/// place (the same node, if there is nothing to do). A layer over the core
/// that adds its own nodes (the shell's, held opaquely in `.extended`) sees
/// them here and rewrites what is inside them itself, with `program`,
/// `expression` and the rest. This is how the shell's constructs become Swift
/// (Docs/Design/desugaring.md).
@_spi(Shell) public struct TreeRewriter {
    @_spi(Shell) public var expr: (Expr) -> Expr
    @_spi(Shell) public var unit: (Unit) -> Unit
    @_spi(Shell) public var statement: (Statement) -> Statement

    @_spi(Shell) public init(
        expr: @escaping (Expr) -> Expr = { $0 },
        unit: @escaping (Unit) -> Unit = { $0 },
        statement: @escaping (Statement) -> Statement = { $0 }
    ) {
        self.expr = expr
        self.unit = unit
        self.statement = statement
    }

    // MARK: Programs and statements

    @_spi(Shell) public func program(_ program: Program) -> Program {
        Program(statements: program.statements.map(self.statementNode), lines: program.lines)
    }

    private func block(_ program: Program?) -> Program? { program.map(self.program) }

    @_spi(Shell) public func statementNode(_ node: Statement) -> Statement {
        let rewritten: Statement
        switch node {
        case .declare(let name, let mutable, let value):
            rewritten = .declare(name: name, mutable: mutable, value: expression(value))
        case .assign(var assignment):
            assignment.path = assignment.path.map { step in
                if case .index(let index) = step { .index(expression(index)) } else { step }
            }
            assignment.value = expression(assignment.value)
            rewritten = .assign(assignment)
        case .function(let decl):
            rewritten = .function(function(decl))
        case .doCatch(let body, let errorName, let handler):
            rewritten = .doCatch(body: program(body), errorName: errorName, handler: block(handler))
        case .enumDecl(var decl):
            decl.cases = decl.cases.map { enumCase in
                var copy = enumCase
                copy.rawValue = enumCase.rawValue.map(expression)
                return copy
            }
            rewritten = .enumDecl(decl)
        case .structDecl(var decl):
            decl.properties = decl.properties.map(property)
            decl.staticProperties = decl.staticProperties.map(property)
            decl.methods = decl.methods.map(function)
            decl.staticMethods = decl.staticMethods.map(function)
            decl.initializers = decl.initializers.map(function)
            rewritten = .structDecl(decl)
        case .extensionDecl(let name, let methods):
            rewritten = .extensionDecl(name: name, methods: methods.map(function))
        case .extended:
            rewritten = node
        case .deferBlock(let body):
            rewritten = .deferBlock(program(body))
        case .fallthroughStatement, .breakStatement, .continueStatement:
            rewritten = node
        case .returnStatement(let value):
            rewritten = .returnStatement(value.map(expression))
        case .guardStatement(let condition, let otherwise):
            rewritten = .guardStatement(self.condition(condition), otherwise: program(otherwise))
        case .chain(let chain):
            rewritten = .chain(self.chain(chain))
        }
        return statement(rewritten)
    }

    @_spi(Shell) public func function(_ decl: FunctionDecl) -> FunctionDecl {
        var copy = decl
        copy.parameters = decl.parameters.map(parameter)
        copy.body = program(decl.body)
        return copy
    }

    @_spi(Shell) public func parameter(_ parameter: Parameter) -> Parameter {
        var copy = parameter
        copy.defaultValue = parameter.defaultValue.map(expression)
        return copy
    }

    private func property(_ decl: PropertyDecl) -> PropertyDecl {
        var copy = decl
        copy.defaultValue = decl.defaultValue.map(expression)
        copy.getter = block(decl.getter)
        return copy
    }

    // MARK: Chains and units

    @_spi(Shell) public func chain(_ chain: Chain) -> Chain {
        Chain(first: unitNode(chain.first), links: chain.links.map { Link(op: $0.op, unit: unitNode($0.unit)) })
    }

    @_spi(Shell) public func unitNode(_ node: Unit) -> Unit {
        let rewritten: Unit
        switch node {
        case .extended:
            rewritten = node
        case .expression(let value):
            rewritten = .expression(expression(value))
        case .ifStatement(let statement):
            rewritten = .ifStatement(ifStatement(statement))
        case .switchStatement(let statement):
            rewritten = .switchStatement(SwitchStatement(
                subject: expression(statement.subject),
                cases: statement.cases.map { switchCase in
                    SwitchCase(
                        patterns: switchCase.patterns.map(pattern), guardExpr: switchCase.guardExpr.map(expression),
                        body: program(switchCase.body)
                    )
                }
            ))
        case .forLoop(let loop):
            rewritten = .forLoop(ForLoop(variable: loop.variable, sequence: expression(loop.sequence), body: program(loop.body)))
        case .whileLoop(let loop):
            rewritten = .whileLoop(WhileLoop(condition: chain(loop.condition), body: program(loop.body)))
        }
        return unit(rewritten)
    }

    @_spi(Shell) public func ifStatement(_ node: IfStatement) -> IfStatement {
        IfStatement(condition: condition(node.condition), then: program(node.then), otherwise: block(node.otherwise))
    }

    private func condition(_ condition: IfStatement.Condition) -> IfStatement.Condition {
        switch condition {
        case .chain(let value): .chain(chain(value))
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
        }
    }

    // MARK: Expressions

    @_spi(Shell) public func arguments(_ arguments: [Argument]) -> [Argument] {
        arguments.map { Argument(label: $0.label, value: expression($0.value)) }
    }

    @_spi(Shell) public func closure(_ closure: ClosureLiteral) -> ClosureLiteral {
        var copy = closure
        copy.parameters = closure.parameters.map(parameter)
        copy.body = program(closure.body)
        return copy
    }

    @_spi(Shell) public func expression(_ node: Expr) -> Expr {
        let rewritten: Expr
        switch node {
        case .literal, .variable, .filePath, .extended:
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
        }
        return expr(rewritten)
    }
}
