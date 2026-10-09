import Foundation
import SwishKit

extension Parser {
    @_spi(Shell) public mutating func parseChain() throws(SyntaxError) -> Chain {
        var chain = Chain(first: try parseUnit())
        while true {
            skipSpaces()
            let op: ChainOperator
            if consume("&&") {
                op = .and
            } else if consume("||") {
                op = .or
            } else {
                return chain
            }
            skipSpaces(newlines: true)
            chain.links.append(Link(op: op, unit: try parseUnit()))
        }
    }

    @_spi(Shell) public mutating func parseUnit() throws(SyntaxError) -> Unit {
        skipSpaces()
        guard peek() != nil else { throw .incomplete("expected a command") }
        switch identifier() {
        case "if":
            return .ifStatement(try parseIf())
        case "for":
            return .forLoop(try parseFor())
        case "while":
            return .whileLoop(try parseWhile())
        case "switch":
            return .switchStatement(try parseSwitch())
        case "case", "default":
            throw SyntaxError("'\(identifier()!)' outside a switch")
        case "else":
            throw SyntaxError("'else' without a matching 'if'")
        case "in":
            throw SyntaxError("unexpected 'in'")
        case let word? where Parser.statementKeywords.contains(word):
            throw SyntaxError("'\(word)' must start a statement")
        default:
            break
        }
        // A unit of the plug-in's, like the shell's commands.
        if let plugin = self.plugin, let unit = try plugin.unit(&self) { return unit }
        let start = pos
        // `a < 1 || b > 2` is one expression, with Swift's precedence, so
        // `{ $0.a < 1 || $0.b > 2 }` returns it. Only when an operand
        // isn't an expression, as in `x > 1 && echo big`, do `&&`/`||`
        // chain units by exit status instead.
        let beforeExpression = self
        var expr: Expr
        do {
            expr = try parseExpression(logical: true)
        } catch {
            // In Swift, an operand that isn't an expression is just an error.
            guard plugin != nil else { throw error }
            self = beforeExpression
            expr = try parseExpression(logical: false)
        }
        skipSpaces()
        guard peek() == "|", peek(1) != "|" else { return .expression(expr) }
        guard let plugin = self.plugin, let unit = try plugin.unit(continuing: expr, from: start, &self) else {
            throw SyntaxError("'|' pipes commands, which are shell syntax, and isn't an operator in Swift-only code")
        }
        return unit
    }

    @_spi(Shell) public mutating func parseIf() throws(SyntaxError) -> IfStatement {
        keyword("if")
        skipSpaces()
        let (condition, bound) = try parseIfCondition()
        skipSpaces()
        let then = try parseBlock(declaring: bound)

        let afterBlock = (pos, spans.count)
        skipSpaces(newlines: true)
        guard identifier() == "else" else {
            rewind(to: afterBlock)
            return IfStatement(condition: condition, then: then)
        }
        keyword("else")
        skipSpaces()
        if identifier() == "if" {
            let elseIf = Statement.chain(Chain(first: .ifStatement(try parseIf())))
            return IfStatement(condition: condition, then: then, otherwise: Program(statements: [elseIf]))
        }
        return IfStatement(condition: condition, then: then, otherwise: try parseBlock())
    }

    /// `guard condition else { … }`, whose bindings last to the block's end.
    @_spi(Shell) public mutating func parseGuard() throws(SyntaxError) -> Statement {
        keyword("guard")
        skipSpaces()
        guardCondition = true
        let parsed = Result { () throws(SyntaxError) in try parseIfCondition() }
        guardCondition = false
        let (condition, bound) = try parsed.get()
        skipSpaces()
        guard identifier() == "else" else { throw expected("'else' after guard's condition") }
        keyword("else")
        skipSpaces()
        let otherwise = try parseBlock()
        for (name, kind) in bound { scopes[scopes.count - 1][name] = kind }
        return .guardStatement(condition, otherwise: otherwise)
    }

    /// An `if` or `guard` condition: a Bool (or command), `let x = y`, or
    /// `case pattern = y`; with the names it binds.
    @_spi(Shell) public mutating func parseIfCondition() throws(SyntaxError) -> (IfStatement.Condition, [String: NameKind]) {
        let condition: IfStatement.Condition
        var bound: [String: NameKind] = [:]
        if identifier() == "case" {
            keyword("case")
            let pattern = try parsePattern()
            skipSpaces()
            guard peek() == "=" && peek(1) != "=" else { throw expected("'=' after the pattern") }
            pos += 1
            conditionDepth += 1
            defer { conditionDepth -= 1 }
            condition = .pattern(pattern, try parseExpression())
            for name in Parser.names(boundBy: pattern) { bound[name] = .variable }
        } else if let word = identifier(), word == "let" || word == "var" {
            keyword(word)
            skipSpaces()
            let nameStart = pos
            let name = try parseName(after: "'\(word)'")
            mark(.variable, from: nameStart)
            skipSpaces()
            guard peek() == "=" && peek(1) != "=" else { throw expected("'=' after '\(name)'") }
            pos += 1
            conditionDepth += 1
            defer { conditionDepth -= 1 }
            condition = .binding(name: name, mutable: word == "var", value: try parseExpression())
            bound[name] = .variable
        } else {
            condition = .chain(try parseCondition())
        }
        return (condition, bound)
    }

    @_spi(Shell) public mutating func parseCondition() throws(SyntaxError) -> Chain {
        conditionDepth += 1
        defer { conditionDepth -= 1 }
        return try parseChain()
    }

    @_spi(Shell) public mutating func parseFor() throws(SyntaxError) -> ForLoop {
        keyword("for")
        skipSpaces()
        let variableStart = pos
        let variable = try parseName(after: "'for'")
        mark(.variable, from: variableStart)
        skipSpaces()
        guard identifier() == "in" else { throw expected("'in'") }
        keyword("in")
        conditionDepth += 1
        let sequence = try parseExpression()
        conditionDepth -= 1
        skipSpaces()
        loopDepth += 1
        defer { loopDepth -= 1 }
        let body = try parseBlock(declaring: variable == "_" ? [:] : [variable: .variable])
        return ForLoop(variable: variable, sequence: sequence, body: body)
    }

    @_spi(Shell) public mutating func parseWhile() throws(SyntaxError) -> WhileLoop {
        keyword("while")
        let condition = try parseCondition()
        skipSpaces()
        loopDepth += 1
        defer { loopDepth -= 1 }
        return WhileLoop(condition: condition, body: try parseBlock())
    }
}
