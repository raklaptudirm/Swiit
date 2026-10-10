import Foundation
import SwishKit

extension Parser {
    /// What starts a statement and isn't an expression: `if`, `for`,
    /// `while` and `switch`; nil for anything else. Words that only make
    /// sense inside one of those are errors here.
    @_spi(Shell) public mutating func parseCompoundStatement() throws(SyntaxError) -> Statement? {
        switch identifier() {
        case "if": return .ifStatement(try parseIf())
        case "for": return .forLoop(try parseFor())
        case "while": return .whileLoop(try parseWhile())
        case "switch": return .switchStatement(try parseSwitch())
        case "case", "default": throw SyntaxError("'\(identifier()!)' outside a switch")
        case "else": throw SyntaxError("'else' without a matching 'if'")
        case "in": throw SyntaxError("unexpected 'in'")
        default: return nil
        }
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
            let elseIf = Statement.ifStatement(try parseIf())
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
            condition = .expression(try parseCondition())
        }
        return (condition, bound)
    }

    /// An `if`, `guard` or `while` condition: a Bool, or the plug-in's (the
    /// shell's `if grep -q x f`).
    @_spi(Shell) public mutating func parseCondition() throws(SyntaxError) -> Expr {
        conditionDepth += 1
        defer { conditionDepth -= 1 }
        skipSpaces()
        guard peek() != nil else { throw .incomplete("expected a condition") }
        if let plugin = self.plugin, let condition = try plugin.chain(&self, condition: true) { return condition }
        return try parseExpression()
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
