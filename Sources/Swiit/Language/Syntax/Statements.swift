import Foundation
import SwiitKit

// MARK: - AST

@_spi(Layer) public struct Program: Equatable, Sendable {
    @_spi(Layer) public var statements: [Statement]
    /// Each statement's line in the source, 1-based, for error messages.
    @_spi(Layer) public var lines: [Int] = []

    /// Programs are equal by what they say, wherever it was written.
    @_spi(Layer) public static func == (lhs: Program, rhs: Program) -> Bool {
        lhs.statements == rhs.statements
    }

    @_spi(Layer) public init(statements: [Statement], lines: [Int] = []) {
        self.statements = statements
        self.lines = lines
    }
}

@_spi(Layer) public enum Statement: Equatable, Sendable {
    case declare(name: String, mutable: Bool, value: Expr)
    /// `x = v`, `p.x += 1`, `xs[0] = v`.
    case assign(Assignment)
    case function(FunctionDecl)
    /// `do { … } catch Oops.bad { … } catch let e as Oops { … } catch { … }`:
    /// an error from the body runs the first clause whose pattern (and
    /// `where`) matches it, as a switch's cases do; a clause without a
    /// pattern matches any, binding `error`. An error none matches goes on.
    case doCatch(body: Program, clauses: [SwitchCase])
    /// `throw Oops(code: 2)`: an Error, which the nearest matching `catch` gets.
    case throwStatement(Expr)
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
    @_spi(Layer) public var declaresType: Bool {
        switch self {
        case .structDecl, .enumDecl: true
        default: false
        }
    }
}

@_spi(Layer) public struct IfStatement: Equatable, Sendable {
    @_spi(Layer) public enum Condition: Equatable, Sendable {
        /// A Bool.
        case expression(Expr)
        /// `if let name = value`: runs the body with `name` bound when the
        /// value isn't nil.
        case binding(name: String, mutable: Bool, value: Expr)
        /// `if case .failed(let code) = result`.
        case pattern(Pattern, Expr)
    }

    @_spi(Layer) public var condition: Condition
    @_spi(Layer) public var then: Program
    @_spi(Layer) public var otherwise: Program?

    /// A branch of an `if` expression: the one expression it is, or an
    /// `else if`'s own `if` expression.
    static func branchExpression(_ branch: Program) -> Expr? {
        guard branch.statements.count == 1 else { return nil }
        switch branch.statements[0] {
        case .expression(let expr): return expr
        case .ifStatement(let node): return node.asExpression.map(Expr.ifExpression)
        default: return nil
        }
    }

    /// A branch that is `expr`.
    @_spi(Layer) public static func branch(_ expr: Expr) -> Program {
        Program(statements: [.expression(expr)])
    }

    /// This `if` as an expression, when it can be one: with an `else`, and
    /// every branch one expression. `else if` branches become expressions too.
    @_spi(Swiit) public var asExpression: IfStatement? {
        guard let otherwise, let thenExpr = IfStatement.branchExpression(then),
              let elseExpr = IfStatement.branchExpression(otherwise) else { return nil }
        return IfStatement(condition: condition, then: IfStatement.branch(thenExpr), otherwise: IfStatement.branch(elseExpr))
    }

    @_spi(Layer) public init(condition: Condition, then: Program, otherwise: Program? = nil) {
        self.condition = condition
        self.then = then
        self.otherwise = otherwise
    }
}

/// `enum Name: RawType { case a, b(label: Type) = raw }`
@_spi(Layer) public struct EnumDecl: Equatable, Sendable {
    @_spi(Layer) public var name: String
    @_spi(Layer) public var rawType: TypeAnnotation?
    @_spi(Layer) public var cases: [EnumCaseDecl]
    /// `enum Level: Int, Comparable`: the protocols after any raw type.
    @_spi(Layer) public var conformances: [String] = []

    @_spi(Layer) public init(name: String, rawType: TypeAnnotation? = nil, cases: [EnumCaseDecl], conformances: [String] = []) {
        self.name = name
        self.rawType = rawType
        self.cases = cases
        self.conformances = conformances
    }
}

@_spi(Layer) public struct EnumCaseDecl: Equatable, Sendable {
    @_spi(Layer) public var name: String
    @_spi(Layer) public var rawValue: Expr?
    @_spi(Layer) public var associated: [AssociatedValue]

    @_spi(Layer) public init(name: String, rawValue: Expr? = nil, associated: [AssociatedValue]) {
        self.name = name
        self.rawValue = rawValue
        self.associated = associated
    }
}

@_spi(Layer) public struct AssociatedValue: Equatable, Sendable {
    @_spi(Layer) public var label: String?
    @_spi(Layer) public var type: TypeAnnotation

    @_spi(Layer) public init(label: String? = nil, type: TypeAnnotation) {
        self.label = label
        self.type = type
    }
}

@_spi(Layer) public struct SwitchStatement: Equatable, Sendable {
    @_spi(Swiit) public var subject: Expr
    @_spi(Layer) public var cases: [SwitchCase]

    @_spi(Layer) public init(subject: Expr, cases: [SwitchCase]) {
        self.subject = subject
        self.cases = cases
    }
}

/// `case p1, p2 where guard: body`; no patterns is `default:`.
@_spi(Layer) public struct SwitchCase: Equatable, Sendable {
    @_spi(Layer) public var patterns: [Pattern]
    @_spi(Layer) public var guardExpr: Expr?
    @_spi(Layer) public var body: Program

    @_spi(Layer) public init(patterns: [Pattern], guardExpr: Expr? = nil, body: Program) {
        self.patterns = patterns
        self.guardExpr = guardExpr
        self.body = body
    }
}

@_spi(Layer) public indirect enum Pattern: Equatable, Sendable {
    /// `_`
    case wildcard
    /// `let x`: matches anything, binding it.
    case binding(name: String, mutable: Bool)
    /// `.failed(code: let c)`, or `Result.failed(…)`; nil arguments match
    /// whatever associated values the case has.
    case enumCase(type: String?, name: String, arguments: [PatternArgument]?)
    /// A value to compare with, or a range to be in: `3`, `"a"`, `1...9`.
    case expression(Expr)
    /// `let e as Oops`, `_ as Int`: a value of that type, matched as one.
    case cast(Pattern, TypeAnnotation)
    /// `is Oops`: a value of that type.
    case isType(TypeAnnotation)
}

extension Pattern {
    /// Whether it matches every value: `_`, `let e`.
    var catchesAll: Bool {
        switch self {
        case .wildcard, .binding: true
        default: false
        }
    }
}

@_spi(Layer) public struct PatternArgument: Equatable, Sendable {
    @_spi(Layer) public var label: String?
    @_spi(Layer) public var pattern: Pattern

    @_spi(Layer) public init(label: String? = nil, pattern: Pattern) {
        self.label = label
        self.pattern = pattern
    }
}

@_spi(Layer) public struct ForLoop: Equatable, Sendable {
    @_spi(Layer) public var variable: String
    @_spi(Layer) public var sequence: Expr
    @_spi(Layer) public var body: Program
    /// `for try await x in s`: s is an AsyncSequence, whose reading waits
    /// (`await`) and may throw (`try`).
    @_spi(Layer) public var isAwait = false
    @_spi(Swiit) public var isTry = false

    @_spi(Layer) public init(variable: String, sequence: Expr, body: Program, isAwait: Bool = false, isTry: Bool = false) {
        self.variable = variable
        self.sequence = sequence
        self.body = body
        self.isAwait = isAwait
        self.isTry = isTry
    }
}

@_spi(Layer) public struct WhileLoop: Equatable, Sendable {
    /// A Bool.
    @_spi(Layer) public var condition: Expr
    @_spi(Layer) public var body: Program

    @_spi(Layer) public init(condition: Expr, body: Program) {
        self.condition = condition
        self.body = body
    }
}
