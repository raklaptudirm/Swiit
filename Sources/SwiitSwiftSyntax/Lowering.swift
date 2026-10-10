@_spi(Shell) import Swiit
import SwiftOperators
import SwiftSyntax
import SwishKit

/// Lowers SwiftParser's tree to the core's. A construct it doesn't lower is a
/// `SyntaxError` that names it, so the supported subset is the set of nodes
/// handled here.
struct Lowering {
    let converter: SourceLocationConverter
    let tree: SourceFileSyntax
    let bound: [String: NameKind]
    /// Struct, enum and typealias names declared by the program, which a type
    /// may name before they are declared.
    var declaredTypes: Set<String> = []
    /// The names bound by the blocks around the code being lowered, innermost
    /// last: a parameter, a `let`, a loop variable, a pattern's binding.
    var locals: [Set<String>] = [[]]
    /// The members of the struct whose body this is, innermost last, which a
    /// bare name in a method reads through `self`.
    var members: [Set<String>] = []
    /// While a static member is lowered: its type and the static members a
    /// bare name there reads through the type's name.
    var staticContext: (owner: String, names: Set<String>)?
    /// The function names declared so far, which a command may call.
    var functions: Set<String> = []
    /// How many `try`s cover the code being lowered, which makes a `$(…)` or an
    /// `await` throw; a function's or closure's body starts afresh.
    var tryDepth = 0
    /// What a `return`, `break`, `continue` or `fallthrough` here can leave.
    var leaving = Leaving()
    /// The layer over the core whose syntax this program may use (the shell's).
    let plugin: (any SyntaxPlugin)?
    let source: String
    let bytes: [UInt8]
    /// For each byte offset into the source, the character it is in.
    let characterOf: [Int]
    /// The byte offset each character starts at, and the end.
    let byteOf: [Int]
    /// The spans of source (in bytes) that the plug-in read: SwiftParser's tree
    /// for them is its best guess at what isn't Swift, and is not looked at.
    var consumed: [Range<Int>] = []
    /// Nodes SwiftParser found something missing in that the core reads as
    /// they are, as a bare `await`.
    var accepted: Set<SyntaxIdentifier> = []
    /// What folding operators found wrong, and where (in bytes): a problem only
    /// outside what the plug-in read, as `f -- --x` is a command's words.
    var operatorProblems: [(message: String, offset: Int)] = []
    /// The highlight spans the plug-in recorded where it read.
    var layerSpans: [Span] = []
    /// Whether to go on past a statement that can't be read, as highlighting
    /// a line half typed does, rather than stop at it.
    var recovering = false
    /// The end of the innermost statement that couldn't be lowered (in bytes).
    var failedEnd: Int?

    init(source: String, tree: SourceFileSyntax, bound: [String: NameKind], plugin: (any SyntaxPlugin)? = nil) {
        self.converter = SourceLocationConverter(fileName: "", tree: tree)
        self.tree = tree
        self.bound = bound
        self.plugin = plugin
        self.source = source
        self.bytes = Array(source.utf8)
        var characterOf: [Int] = []
        var byteOf: [Int] = []
        for (index, character) in source.enumerated() {
            byteOf.append(characterOf.count)
            characterOf += Array(repeating: index, count: String(character).utf8.count)
        }
        byteOf.append(characterOf.count)
        characterOf.append(source.count)
        self.characterOf = characterOf
        self.byteOf = byteOf
    }

    func unsupported(_ what: String, _ node: some SyntaxProtocol) -> SyntaxError {
        SyntaxError("\(what) isn't supported by this front end yet (line \(line(of: node)))")
    }

    func line(of node: some SyntaxProtocol) -> Int {
        converter.location(for: node.positionAfterSkippingLeadingTrivia).line
    }

    // MARK: Programs

    mutating func program() throws -> Program {
        for item in tree.statements { collectTypeNames(item.item) }
        // A SwiftParser tree that has problems has them in `unexpected` nodes
        // and missing tokens; the first one outside what the plug-in read is
        // the error, and comes before whatever else went wrong.
        let lowered: Program
        do {
            lowered = try block(tree.statements, scoped: false)
        } catch {
            // A problem in or before the statement that couldn't be lowered
            // explains it; one further on is in code not yet read, where the
            // plug-in's syntax may be.
            if let (problem, offset) = firstProblem(in: tree), offset <= failedEnd ?? Int.max { throw problem }
            throw error
        }
        if let (problem, _) = firstProblem(in: tree) { throw problem }
        if let problem = operatorProblems.first(where: { problem in !consumed.contains { $0.contains(problem.offset) } }) {
            throw SyntaxError("\(problem.message) (line \(converter.location(for: AbsolutePosition(utf8Offset: problem.offset)).line))")
        }
        return lowered
    }

    // MARK: The layer's syntax

    /// The names the plug-in's parser needs to know, as the code being lowered has them.
    func names() -> [String: NameKind] {
        var names = bound
        for name in declaredTypes { names[name] = .type }
        for scope in locals { for name in scope { names[name] = .variable } }
        // A declared function is called by its name even where it is bound as a value.
        for name in functions { names[name] = .function }
        if !members.isEmpty { names["self"] = .variable }
        for name in members.last ?? [] where names[name] == nil { names[name] = .member }
        if let context = staticContext { for name in context.names { names[name] = .staticMember(of: context.owner) } }
        return names
    }

    /// A parser for the plug-in to read from, positioned at the byte offset.
    func cursor(at byteOffset: Int) -> Parser {
        var parser = Parser(source, bound: names())
        parser.plugin = plugin
        parser.tryDepth = tryDepth
        parser.functionDepth = leaving.function
        parser.loopDepth = leaving.loop
        parser.switchDepth = leaving.switchCase
        parser.pos = characterOf[min(byteOffset, characterOf.count - 1)]
        return parser
    }

    /// Where a parser stopped, as a byte offset.
    func byteOffset(of parser: Parser) -> Int {
        byteOf[min(parser.pos, byteOf.count - 1)]
    }

    /// Notes that the plug-in read from `start` to where its parser stopped.
    mutating func consume(from start: Int, to parser: Parser) {
        consumed.append(start..<max(byteOffset(of: parser), start))
        layerSpans += parser.spans
    }

    mutating func block(_ items: CodeBlockItemListSyntax, scoped: Bool = true) throws -> Program {
        if scoped { locals.append([]) }
        defer { if scoped { locals.removeLast() } }
        // Functions can be called before their declarations, as in Swift.
        for item in items {
            if case .decl(let decl) = item.item, let function = decl.as(FunctionDeclSyntax.self) { functions.insert(function.name.text) }
        }
        var statements: [Statement] = []
        var lines: [Int] = []
        var skipUntil = 0
        // Where the last statement the layer read ended, if the item it began swallowed more.
        var islandEnd: Int?
        for item in items {
            let start = item.positionAfterSkippingLeadingTrivia.utf8Offset
            if start < skipUntil { continue }
            if let end = islandEnd {
                // What it reads may run past the item, which then reads on from there.
                islandEnd = try drain(from: end, skipUntil: &skipUntil, until: start, into: &statements, lines: &lines) ? skipUntil : nil
            }
            if start < skipUntil { continue }
            // A statement of the plug-in's (a command, `import`), read by it.
            let read: (statement: Statement, end: Int)?
            do {
                read = try layerStatement(at: start, item: item.item)
            } catch where recovering {
                skipUntil = max(skipUntil, consumed.last?.upperBound ?? start)
                continue
            } catch {
                failedEnd = failedEnd ?? item.endPosition.utf8Offset
                throw error
            }
            if let island = read {
                statements.append(island.statement)
                lines.append(line(of: item))
                skipUntil = island.end
                islandEnd = island.end
                continue
            }
            let lowered: [Statement]
            do {
                lowered = try statement(item.item)
            } catch where recovering {
                continue
            } catch {
                failedEnd = failedEnd ?? item.endPosition.utf8Offset
                throw error
            }
            // Whatever the layer read inside the item is the item's end too.
            if let last = consumed.last, last.lowerBound >= start { skipUntil = max(skipUntil, last.upperBound) }
            lines += [line(of: item)] + Array(repeating: line(of: item), count: max(lowered.count - 1, 0))
            statements += lowered
        }
        if let end = islandEnd {
            // Up to what closes the block (`}`, or the end of the source), as
            // SwiftParser may have left the last of it out of every item.
            let limit = blockEnd(items)
            _ = try drain(from: end, skipUntil: &skipUntil, until: limit, into: &statements, lines: &lines)
        }
        return Program(statements: statements, lines: lines)
    }

    /// SwiftParser can read one item over several of the layer's statements
    /// (`ls > out; head out`, which it takes for a regular expression): those
    /// the plug-in read before `limit`, past where the last one ended.
    /// Where a block's statements end: at its `}`, or the end of the source.
    private func blockEnd(_ items: CodeBlockItemListSyntax) -> Int {
        if items.parent?.is(SourceFileSyntax.self) == true { return bytes.count }
        if let block = items.parent?.as(CodeBlockSyntax.self) { return block.rightBrace.positionAfterSkippingLeadingTrivia.utf8Offset }
        if let closure = items.parent?.as(ClosureExprSyntax.self) { return closure.rightBrace.positionAfterSkippingLeadingTrivia.utf8Offset }
        return items.endPositionBeforeTrailingTrivia.utf8Offset
    }

    /// Whether it read any.
    private mutating func drain(from end: Int, skipUntil: inout Int, until limit: Int, into statements: inout [Statement], lines: inout [Int]) throws -> Bool {
        skipUntil = end
        var readAny = false
        while true {
            // Past blanks, comments and `;`, as the hand parser skips them.
            var gap = cursor(at: skipUntil)
            while true {
                gap.skipSpaces(newlines: true)
                guard gap.peek() == ";" else { break }
                gap.pos += 1
            }
            let at = byteOffset(of: gap)
            guard at < limit else { return readAny }
            let read: (statement: Statement, end: Int)?
            do {
                read = try layerStatement(at: at)
            } catch where recovering {
                return readAny
            }
            guard let island = read else { return readAny }
            readAny = true
            statements.append(island.statement)
            lines.append(converter.location(for: AbsolutePosition(utf8Offset: at)).line)
            skipUntil = island.end
        }
    }

    mutating func collectTypeNames(_ item: CodeBlockItemSyntax.Item) {
        if case .decl(let decl) = item {
            if let node = decl.as(StructDeclSyntax.self) { declaredTypes.insert(node.name.text) }
            if let node = decl.as(EnumDeclSyntax.self) { declaredTypes.insert(node.name.text) }
        }
    }

    /// The first problem SwiftParser found, and where (in bytes).
    func firstProblem(in tree: some SyntaxProtocol) -> (SyntaxError, Int)? {
        let finder = ProblemFinder(end: tree.endPositionBeforeTrailingTrivia, consumed: consumed, accepted: accepted)
        finder.walk(tree)
        guard let (message, position) = finder.found else { return nil }
        let line = converter.location(for: position).line
        let text = "\(message) (line \(line))"
        return (finder.incomplete ? .incomplete(text) : SyntaxError(text), position.utf8Offset)
    }
}

/// How many functions, loops and switch cases are around the code being
/// lowered: nothing leaves a `defer`, and a function's body leaves only it.
struct Leaving {
    var function = 0
    var loop = 0
    var switchCase = 0
}

private final class ProblemFinder: SyntaxVisitor {
    var found: (String, AbsolutePosition)?
    var incomplete = false
    let end: AbsolutePosition
    let consumed: [Range<Int>]
    let accepted: Set<SyntaxIdentifier>
    init(end: AbsolutePosition, consumed: [Range<Int>], accepted: Set<SyntaxIdentifier>) {
        self.end = end
        self.consumed = consumed
        self.accepted = accepted
        super.init(viewMode: .all)
    }
    private func isConsumed(_ offset: Int) -> Bool {
        consumed.contains { $0.contains(offset) }
    }
    /// Whether a missing token is in what the plug-in read: it is missing from
    /// a node that starts there, within its statement (`'a b'`, a string with
    /// its quotes missing to SwiftParser, at the end of a command).
    private func isInLayer(_ token: TokenSyntax) -> Bool {
        if isConsumed(token.position.utf8Offset) { return true }
        var node = token.parent
        while let current = node {
            if accepted.contains(current.id) { return true }
            if isConsumed(current.positionAfterSkippingLeadingTrivia.utf8Offset) { return true }
            if current.is(CodeBlockItemSyntax.self) || current.is(MemberBlockItemSyntax.self) { return false }
            node = current.parent
        }
        return false
    }
    override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
        if found == nil, token.presence == .missing, !isInLayer(token) {
            found = ("expected \(token.tokenKind)", token.position)
            if token.position >= end { incomplete = true }
        }
        return .skipChildren
    }
    override func visit(_ node: UnexpectedNodesSyntax) -> SyntaxVisitorContinueKind {
        if found == nil, !isConsumed(node.positionAfterSkippingLeadingTrivia.utf8Offset), node.parent.map({ accepted.contains($0.id) }) != true {
            found = ("unexpected '\(node.trimmedDescription)'", node.position)
        }
        return .skipChildren
    }
}
