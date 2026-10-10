import Foundation
import SwishKit

// MARK: - AST

@_spi(Shell) public struct Program: Equatable, Sendable {
    @_spi(Shell) public var statements: [Statement]
    /// Each statement's line in the source, 1-based, for error messages.
    @_spi(Shell) public var lines: [Int] = []

    /// Programs are equal by what they say, wherever it was written.
    @_spi(Shell) public static func == (lhs: Program, rhs: Program) -> Bool {
        lhs.statements == rhs.statements
    }

    @_spi(Shell) public init(statements: [Statement], lines: [Int] = []) {
        self.statements = statements
        self.lines = lines
    }
}

@_spi(Shell) public enum Statement: Equatable, Sendable {
    case declare(name: String, mutable: Bool, value: Expr)
    /// `x = v`, `p.x += 1`, `xs[0] = v`.
    case assign(Assignment)
    case function(FunctionDecl)
    /// `do { … } catch { … }`: a runtime error in the body runs the
    /// handler with `error` (or the name given) bound to it.
    case doCatch(body: Program, errorName: String, handler: Program?)
    case enumDecl(EnumDecl)
    case structDecl(StructDecl)
    /// `extension Sequence { func filter(…) … }`: the prelude's methods of
    /// every sequence.
    case extensionDecl(name: String, methods: [FunctionDecl])
    /// Syntax a layer over the core adds: the shell's `env.NAME = value` and
    /// `import Tools from "./Tools"` (Language/Syntax/SyntaxExtension.swift).
    case extended(StatementExtensionBox)
    /// `defer { … }`: runs when the block it's in ends, however it ends,
    /// last deferred first. At a script's top level, when the script ends.
    case deferBlock(Program)
    /// Carries on into the next case of a switch.
    case fallthroughStatement
    case returnStatement(Expr?)
    /// `guard let x = y else { return }`: unless the condition holds, runs
    /// the `else`, which must leave the block; what it binds stays bound
    /// for the rest of the block.
    case guardStatement(IfStatement.Condition, otherwise: Program)
    case breakStatement
    case continueStatement
    /// An expression on its own: a call, an assignment's value, or at the
    /// prompt, a value to show.
    case expression(Expr)
    case ifStatement(IfStatement)
    case switchStatement(SwitchStatement)
    case forLoop(ForLoop)
    case whileLoop(WhileLoop)
}

extension Statement {
    /// A struct or enum declaration, which a block declares before it runs.
    @_spi(Shell) public var declaresType: Bool {
        switch self {
        case .structDecl, .enumDecl: true
        default: false
        }
    }
}

@_spi(Shell) public struct IfStatement: Equatable, Sendable {
    @_spi(Shell) public enum Condition: Equatable, Sendable {
        /// A Bool.
        case expression(Expr)
        /// `if let name = value`: runs the body with `name` bound when the
        /// value isn't nil.
        case binding(name: String, mutable: Bool, value: Expr)
        /// `if case .failed(let code) = result`.
        case pattern(Pattern, Expr)
    }

    @_spi(Shell) public var condition: Condition
    @_spi(Shell) public var then: Program
    @_spi(Shell) public var otherwise: Program?

    /// A branch of an `if` expression: the one expression it is, or an
    /// `else if`'s own `if` expression.
    @_spi(Shell) public static func branchExpression(_ branch: Program) -> Expr? {
        guard branch.statements.count == 1 else { return nil }
        switch branch.statements[0] {
        case .expression(let expr): return expr
        case .ifStatement(let node): return node.asExpression.map(Expr.ifExpression)
        default: return nil
        }
    }

    /// A branch that is `expr`.
    @_spi(Shell) public static func branch(_ expr: Expr) -> Program {
        Program(statements: [.expression(expr)])
    }

    /// This `if` as an expression, when it can be one: with an `else`, and
    /// every branch one expression. `else if` branches become expressions too.
    @_spi(Shell) public var asExpression: IfStatement? {
        guard let otherwise, let thenExpr = IfStatement.branchExpression(then),
              let elseExpr = IfStatement.branchExpression(otherwise) else { return nil }
        return IfStatement(condition: condition, then: IfStatement.branch(thenExpr), otherwise: IfStatement.branch(elseExpr))
    }

    @_spi(Shell) public init(condition: Condition, then: Program, otherwise: Program? = nil) {
        self.condition = condition
        self.then = then
        self.otherwise = otherwise
    }
}

/// `enum Name: RawType { case a, b(label: Type) = raw }`
@_spi(Shell) public struct EnumDecl: Equatable, Sendable {
    @_spi(Shell) public var name: String
    @_spi(Shell) public var rawType: TypeAnnotation?
    @_spi(Shell) public var cases: [EnumCaseDecl]
    /// `enum Level: Int, Comparable`: the protocols after any raw type.
    @_spi(Shell) public var conformances: [String] = []

    @_spi(Shell) public init(name: String, rawType: TypeAnnotation? = nil, cases: [EnumCaseDecl], conformances: [String] = []) {
        self.name = name
        self.rawType = rawType
        self.cases = cases
        self.conformances = conformances
    }
}

@_spi(Shell) public struct EnumCaseDecl: Equatable, Sendable {
    @_spi(Shell) public var name: String
    @_spi(Shell) public var rawValue: Expr?
    @_spi(Shell) public var associated: [AssociatedValue]

    @_spi(Shell) public init(name: String, rawValue: Expr? = nil, associated: [AssociatedValue]) {
        self.name = name
        self.rawValue = rawValue
        self.associated = associated
    }
}

@_spi(Shell) public struct AssociatedValue: Equatable, Sendable {
    @_spi(Shell) public var label: String?
    @_spi(Shell) public var type: TypeAnnotation

    @_spi(Shell) public init(label: String? = nil, type: TypeAnnotation) {
        self.label = label
        self.type = type
    }
}

@_spi(Shell) public struct SwitchStatement: Equatable, Sendable {
    @_spi(Shell) public var subject: Expr
    @_spi(Shell) public var cases: [SwitchCase]

    @_spi(Shell) public init(subject: Expr, cases: [SwitchCase]) {
        self.subject = subject
        self.cases = cases
    }
}

/// `case p1, p2 where guard: body`; no patterns is `default:`.
@_spi(Shell) public struct SwitchCase: Equatable, Sendable {
    @_spi(Shell) public var patterns: [Pattern]
    @_spi(Shell) public var guardExpr: Expr?
    @_spi(Shell) public var body: Program

    @_spi(Shell) public init(patterns: [Pattern], guardExpr: Expr? = nil, body: Program) {
        self.patterns = patterns
        self.guardExpr = guardExpr
        self.body = body
    }
}

@_spi(Shell) public indirect enum Pattern: Equatable, Sendable {
    /// `_`
    case wildcard
    /// `let x`: matches anything, binding it.
    case binding(name: String, mutable: Bool)
    /// `.failed(code: let c)`, or `Result.failed(…)`; nil arguments match
    /// whatever associated values the case has.
    case enumCase(type: String?, name: String, arguments: [PatternArgument]?)
    /// A value to compare with, or a range to be in: `3`, `"a"`, `1...9`.
    case expression(Expr)
}

@_spi(Shell) public struct PatternArgument: Equatable, Sendable {
    @_spi(Shell) public var label: String?
    @_spi(Shell) public var pattern: Pattern

    @_spi(Shell) public init(label: String? = nil, pattern: Pattern) {
        self.label = label
        self.pattern = pattern
    }
}

@_spi(Shell) public struct ForLoop: Equatable, Sendable {
    @_spi(Shell) public var variable: String
    @_spi(Shell) public var sequence: Expr
    @_spi(Shell) public var body: Program

    @_spi(Shell) public init(variable: String, sequence: Expr, body: Program) {
        self.variable = variable
        self.sequence = sequence
        self.body = body
    }
}

@_spi(Shell) public struct WhileLoop: Equatable, Sendable {
    /// A Bool.
    @_spi(Shell) public var condition: Expr
    @_spi(Shell) public var body: Program

    @_spi(Shell) public init(condition: Expr, body: Program) {
        self.condition = condition
        self.body = body
    }
}
