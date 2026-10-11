import Foundation
import SwiftOperators
import SwiftParser
import SwiftSyntax
import SwiitKit

/// The Swift inside a layer's forms, read for it. A layer's syntax holds Swift
/// in a few places (a `(…)` or `{ … }` word, `\(…)` in a string, the program in
/// `$(…)`), and it reads those with `parseExpression`, `parseClosure`,
/// `parseArguments` and `parseProgram`, here: each lowers the source from the
/// cursor on, in a lowering of its own that starts knowing what the names
/// around are, and moves the cursor to where the Swift ended.
///
/// The source is given to SwiftParser a few lines at a time, from the cursor's
/// line: what the layer reads is mostly a line long, and when a construct isn't
/// finished (it reads as input cut short), the window grows by lines and it is
/// read again, so reading costs about what is read, not what follows it.
extension SourceCursor {
    // MARK: Entry points

    /// An expression, as Swift reads one here; `logical: false` stops before a
    /// top-level `&&` or `||`, which the layer may be joining commands with.
    /// Names must be bound: a word that isn't one is not an expression.
    @_spi(Layer) public mutating func parseExpression(logical: Bool = true) throws(SyntaxError) -> Expr {
        skipSpaces()
        guard peek() != nil else { throw .incomplete("expected an expression") }
        let condition = conditionDepth > 0
        return try swift { lowering in
            let item = try lowering.firstItem()
            guard case .expr(let node) = item.item else { throw SyntaxError("expected an expression") }
            try lowering.endBeforeJoiners(of: node, logical: logical, condition: condition)
            return try lowering.reading(node) { try $0.expression(node) }
        }
    }

    /// A closure, positioned at its opening brace: `{ x, y in … }`,
    /// `{ (x: Int) -> Int in … }`, or `{ $0 * 2 }`.
    @_spi(Layer) public mutating func parseClosure() throws(SyntaxError) -> ClosureLiteral {
        let condition = false
        return try swift { lowering in
            let item = try lowering.firstItem()
            guard case .expr(let expr) = item.item else { throw SyntaxError("expected a closure") }
            try lowering.endBeforeJoiners(of: expr, logical: true, condition: condition)
            guard let node = expr.as(ClosureExprSyntax.self) else { throw SyntaxError("expected a closure") }
            return try lowering.reading(node) { try $0.closure(node) }
        }
    }

    /// A call's arguments, positioned at the opening parenthesis: `(by: "size")`.
    @_spi(Layer) public mutating func parseArguments() throws(SyntaxError) -> [Argument] {
        let condition = false
        return try swift { lowering in
            let item = try lowering.firstItem()
            guard case .expr(let expr) = item.item else { throw SyntaxError("expected arguments") }
            try lowering.endBeforeJoiners(of: expr, logical: true, condition: condition)
            // A closure right after is a trailing one: the parentheses are its callee.
            var tuple = expr.as(TupleExprSyntax.self)
            if tuple == nil, let call = expr.as(FunctionCallExprSyntax.self), call.arguments.isEmpty {
                tuple = call.calledExpression.as(TupleExprSyntax.self)
            }
            guard let tuple else { throw SyntaxError("expected arguments") }
            return try lowering.reading(tuple) { try $0.arguments(tuple.elements) }
        }
    }

    /// Statements up to `terminator`, which is left unread: the program in `$(…)`.
    /// What each declares is known to the ones after it.
    @_spi(Layer) public mutating func parseProgram(until terminator: Character) throws(SyntaxError) -> Program {
        var statements: [Statement] = []
        var lines: [Int] = []
        while true {
            skipSeparators()
            guard let c = peek() else { throw .incomplete("expected '\(terminator)'") }
            if c == terminator { break }
            let line = line(at: pos) + lineOffset
            var lowered: [Statement] = []
            var declared: (variables: Set<String>, functions: Set<String>, types: Set<String>) = ([], [], [])
            lowered = try swift(strict: false) { lowering in
                let (statements, end) = try lowering.readStatement(at: 0)
                declared = (lowering.locals.first ?? [], lowering.functions, lowering.declaredTypes)
                return (statements, end)
            }
            for name in declared.variables { scopes[scopes.count - 1][name] = .variable }
            for name in declared.functions { scopes[scopes.count - 1][name] = .function }
            for name in declared.types { scopes[scopes.count - 1][name] = .type }
            statements += lowered
            lines += Array(repeating: line, count: lowered.count)
        }
        return Program(statements: statements, lines: lines)
    }

    // MARK: Windows

    /// The line, of this source's own, a character is on (from 1).
    func line(at index: Int) -> Int {
        var low = 0
        var high = lineStarts.count
        while low + 1 < high {
            let middle = (low + high) / 2
            if lineStarts[middle] <= index { low = middle } else { high = middle }
        }
        return low + 1
    }

    /// Lowers what is at the cursor in a lowering of its own, over a window of
    /// the source that grows until the construct is whole, and moves the cursor
    /// to where it ended. On an error, to where it went wrong (a layer asks
    /// whether that was in its first word).
    private mutating func swift<T>(strict: Bool = true, _ read: (inout Lowering) throws -> (T, end: Int)) throws(SyntaxError) -> T {
        var lines = 1
        // Where the window ends, once a reading has asked for it cut short.
        var cut: Int?
        while true {
            var limit = pos
            var seen = 0
            while limit < chars.count {
                if chars[limit] == "\n" {
                    seen += 1
                    if seen == lines { break }
                }
                limit += 1
            }
            if let cut { limit = min(limit, pos + cut) }
            let text = String(chars[pos..<limit])
            var lowering: Lowering
            do {
                lowering = try makeLowering(over: text, strict: strict)
            } catch {
                throw (error as? SyntaxError) ?? SyntaxError("\(error)")
            }
            do {
                let (value, end) = try read(&lowering)
                let ended = lowering.characterOf[min(end, lowering.characterOf.count - 1)]
                spans += lowering.spans(before: ended).map { Span(range: ($0.range.lowerBound + pos)..<($0.range.upperBound + pos), kind: $0.kind) }
                pos += ended
                return value
            } catch let end as EndsAt {
                // What it read goes on into the layer's own syntax: read what is before.
                cut = lowering.characterOf[min(end.offset, lowering.characterOf.count - 1)]
                continue
            } catch let error as SyntaxError {
                if error.incomplete, limit < chars.count, cut == nil {
                    lines *= 2
                    continue
                }
                let stopped = lowering.failedAt.map { lowering.characterOf[min($0, lowering.characterOf.count - 1)] } ?? 0
                spans += lowering.spans(before: stopped).map { Span(range: ($0.range.lowerBound + pos)..<($0.range.upperBound + pos), kind: $0.kind) }
                pos += stopped
                throw error
            } catch {
                throw SyntaxError("\(error)")
            }
        }
    }

    /// A lowering of `text` as if it were a file, knowing the names the cursor
    /// does and what the lowering that made it did.
    private func makeLowering(over text: String, strict: Bool) throws -> Lowering {
        var flat: [String: NameKind] = [:]
        for scope in scopes { flat.merge(scope) { $1 } }
        var lowering = try SwiftSyntaxFrontEnd().lowering(of: text, bound: flat, plugin: plugin)
        var inherited = context
        inherited.bound = flat
        lowering.context = inherited
        lowering.strictNames = strict
        lowering.lineOffset = lineOffset + line(at: pos) - 1
        return lowering
    }
}

/// A reading that ends sooner than the window does: the source goes on into
/// the layer's own syntax, at this byte offset, and the window is cut there.
private struct EndsAt: Error {
    let offset: Int
}

extension Lowering {
    /// Lowers what is in `node`, which is wrong if SwiftParser found something
    /// wrong in it (what is missing, what is unexpected, an operator that doesn't
    /// fold) or the lowering did: whichever is first in the text, as it reads.
    /// The lowering goes first, as it knows what the layer accepts as it is (a
    /// bare `await`). With the end of what was read, which takes in what the
    /// layer read inside it.
    mutating func reading<T>(_ node: some SyntaxProtocol, _ lower: (inout Lowering) throws -> T) throws -> (T, end: Int) {
        let start = node.positionAfterSkippingLeadingTrivia.utf8Offset
        let end = node.endPositionBeforeTrailingTrivia.utf8Offset
        let outcome = Result { try lower(&self) }
        var problem: (error: SyntaxError, offset: Int)?
        if let (error, offset) = firstProblem(in: node, end: AbsolutePosition(utf8Offset: bytes.count)) {
            problem = (error, offset)
        } else if let found = operatorProblems.first(where: { $0.offset >= start && $0.offset < end }) {
            problem = (SyntaxError("\(found.message) (line \(line(atByte: found.offset)))"), found.offset)
        }
        switch outcome {
        case .success(let value):
            if let problem {
                failedAt = problem.offset
                throw problem.error
            }
            return (value, extent(of: node))
        case .failure(let error):
            // What was wrong first is the error, and where the reading stopped.
            if let problem, failedAt.map({ problem.offset < $0 }) ?? true {
                failedAt = problem.offset
                throw problem.error
            }
            throw error
        }
    }

    /// Where what was read ends: the node's own text, or further, where the
    /// layer read on inside it (SwiftParser sees `async` in `async sleep 1`).
    func extent(of node: some SyntaxProtocol) -> Int {
        let start = node.positionAfterSkippingLeadingTrivia.utf8Offset
        let layer = consumed.filter { $0.lowerBound >= start }.map(\.upperBound).max() ?? 0
        let hinted = extentHints.filter { $0 >= start }.max() ?? 0
        return max(realEnd(of: node), layer, hinted)
    }

    /// The highlight spans of what is read, up to a character offset.
    func spans(before end: Int) -> [Span] {
        highlightSpans().filter { $0.range.upperBound <= end }
    }
}

extension Lowering {
    /// The layer joins what it reads with `|` (`xs | sorted`), and with `&&`
    /// and `||` (`x > 1 && echo big`) where `logical` is false; to Swift those
    /// are operators. In a condition, a `{` after what is read starts the body,
    /// not a trailing closure. An expression ends before the first of these
    /// that is at its top level, so the window is cut there and read again.
    func endBeforeJoiners(of expr: ExprSyntax, logical: Bool, condition: Bool) throws {
        guard let offset = firstJoiner(in: Syntax(expr), logical: logical, condition: condition) else { return }
        throw EndsAt(offset: offset)
    }

    private func firstJoiner(in node: Syntax, logical: Bool, condition: Bool) -> Int? {
        func earliest(_ nodes: [Syntax]) -> Int? {
            nodes.compactMap { firstJoiner(in: $0, logical: logical, condition: condition) }.min()
        }
        if let infix = node.as(InfixOperatorExprSyntax.self) {
            let op = infix.operator.as(BinaryOperatorExprSyntax.self)?.operator.text
            let own = op == "|" || (!logical && (op == "&&" || op == "||")) ? infix.operator.positionAfterSkippingLeadingTrivia.utf8Offset : nil
            return ([own] + [earliest([Syntax(infix.leftOperand), Syntax(infix.rightOperand)])]).compactMap { $0 }.min()
        }
        if let ternary = node.as(TernaryExprSyntax.self) {
            return earliest([Syntax(ternary.condition), Syntax(ternary.thenExpression), Syntax(ternary.elseExpression)])
        }
        if let wrapper = node.as(TryExprSyntax.self) { return earliest([Syntax(wrapper.expression)]) }
        if let wrapper = node.as(AwaitExprSyntax.self) { return earliest([Syntax(wrapper.expression)]) }
        if let prefix = node.as(PrefixOperatorExprSyntax.self) { return earliest([Syntax(prefix.expression)]) }
        // `x?` alone: Swift's optional chaining goes on with a member or a subscript, so what
        // ends here is before the `?`.
        if let chained = node.as(OptionalChainingExprSyntax.self) {
            return [chained.questionMark.positionAfterSkippingLeadingTrivia.utf8Offset, earliest([Syntax(chained.expression)])].compactMap { $0 }.min()
        }
        guard condition else { return nil }
        // What a condition's `{` could be a trailing closure of: a call, down the chain it ends.
        if let call = node.as(FunctionCallExprSyntax.self) {
            if let closure = call.trailingClosure { return closure.leftBrace.positionAfterSkippingLeadingTrivia.utf8Offset }
            return earliest([Syntax(unchained(call.calledExpression))])
        }
        if let member = node.as(MemberAccessExprSyntax.self), let base = member.base { return earliest([Syntax(unchained(base))]) }
        if let call = node.as(SubscriptCallExprSyntax.self) {
            if let closure = call.trailingClosure { return closure.leftBrace.positionAfterSkippingLeadingTrivia.utf8Offset }
            return earliest([Syntax(call.calledExpression)])
        }
        if let force = node.as(ForceUnwrapExprSyntax.self) { return earliest([Syntax(unchained(force.expression))]) }
        return nil
    }

    /// What a postfix chain's `?` goes on from.
    private func unchained(_ expr: ExprSyntax) -> ExprSyntax {
        expr.as(OptionalChainingExprSyntax.self)?.expression ?? expr
    }
}
