import Foundation

/// A function or closure body written for a `@resultBuilder`, as plain code: each
/// expression is a component, and the components are given to the builder's
/// `buildBlock` (with `buildExpression`, `buildOptional`, `buildEither`, `buildArray` and
/// `buildFinalResult` where it has them), as Swift's compiler does.
struct ResultBuilderTransform {
    let builder: String
    let methods: Set<String>
    private var counter = 0

    init(builder: String, methods: Set<String>) {
        self.builder = builder
        self.methods = methods
    }

    private func build(_ name: String, _ arguments: [Argument]) -> Expr {
        .call(.member(.variable(builder), name), arguments)
    }

    private mutating func fresh() -> String {
        counter += 1
        return "$component\(counter)"
    }

    private func closureCall(_ body: Program, parameters: [Parameter] = [], arguments: [Argument] = []) -> Expr {
        .call(.closure(ClosureLiteral(parameters: parameters, body: body)), arguments)
    }

    mutating func transform(_ body: Program) throws -> Program {
        var statements: [Statement] = []
        var components: [Expr] = []
        func add(_ value: Expr, into statements: inout [Statement], _ name: String) {
            statements.append(.declare(name: name, mutable: false, value: value))
            components.append(.variable(name))
        }
        for statement in body.statements {
            switch statement {
            case .expression(let expr):
                let name = fresh()
                let value = methods.contains("buildExpression") ? build("buildExpression", [Argument(value: expr)]) : expr
                add(value, into: &statements, name)
            case .ifStatement(let node):
                let name = fresh()
                let then = closureCall(try transform(node.then))
                if let otherwise = node.otherwise {
                    guard methods.contains("buildEither") else { throw SyntaxError("\(builder) needs buildEither(first:) and buildEither(second:) for an 'if' with an 'else'") }
                    let first = build("buildEither", [Argument(label: "first", value: then)])
                    let second = build("buildEither", [Argument(label: "second", value: closureCall(try transform(otherwise)))])
                    add(.ifExpression(IfStatement(condition: node.condition, then: IfStatement.branch(first), otherwise: IfStatement.branch(second))),
                        into: &statements, name)
                } else {
                    guard methods.contains("buildOptional") else { throw SyntaxError("\(builder) needs buildOptional to have an 'if' without an 'else'") }
                    let some = IfStatement(condition: node.condition, then: IfStatement.branch(then), otherwise: IfStatement.branch(.literal(.nothing)))
                    add(build("buildOptional", [Argument(value: .ifExpression(some))]), into: &statements, name)
                }
            case .forLoop(let loop):
                guard methods.contains("buildArray") else { throw SyntaxError("\(builder) needs buildArray to have a 'for' in it") }
                let name = fresh()
                var parameter = Parameter(name: "_")
                switch loop.pattern {
                case .binding(let bound, _): parameter = Parameter(name: bound)
                case .wildcard: break
                default: throw SyntaxError("a 'for' in a result builder binds one name or _")
                }
                let items = Expr.call(.member(loop.sequence, "map"), [Argument(value: .closure(ClosureLiteral(parameters: [parameter], body: try transform(loop.body))))])
                add(build("buildArray", [Argument(value: items)]), into: &statements, name)
            case .switchStatement, .whileLoop, .doCatch, .guardStatement, .returnStatement:
                throw SyntaxError("a result builder's body can't use this statement")
            default:
                statements.append(statement)
            }
        }
        var result = build("buildBlock", components.map { Argument(value: $0) })
        if methods.contains("buildFinalResult") { result = build("buildFinalResult", [Argument(value: result)]) }
        statements.append(.returnStatement(result))
        return Program(statements: statements)
    }
}
