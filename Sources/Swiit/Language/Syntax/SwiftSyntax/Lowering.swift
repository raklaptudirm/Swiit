import Foundation
import SwiftOperators
import SwiftSyntax
import SwiitKit

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
    /// The source's characters, made once: each cursor shares them.
    let characters: [Character]
    /// Where each line of them starts.
    let lineStarts: [Int]
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
    /// Where readings ended that SwiftParser's own text doesn't show: a raw
    /// string `'a b'` is its quotes missing, set aside as unexpected.
    var extentHints: [Int] = []
    /// What the layer found wrong with what it read: when it reads a command
    /// at all, what is wrong in it is its own to say.
    var layerError: SyntaxError?
    /// Reading the prelude, the builtins' declarations (Prelude.swift): a
    /// function without a body has one in Swift, and `extension Sequence`
    /// declares the methods every sequence has.
    var prelude = false
    /// The closures around the code being lowered, innermost last: whether
    /// each takes `$0`, `$1`, … (one without named parameters does).
    var anonymous: [Bool] = []
    /// An `import` came before: the functions it brings aren't known until it
    /// runs, so calling an unknown name is left for then.
    var sawImport = false
    /// Where a name that isn't bound is an error, as the layer's reading of a
    /// unit needs (a word that isn't a name is a command's): the Swift here
    /// is read by what the names around it are.
    var strictNames = false
    /// Where the last error was, in bytes, for the cursor that asked.
    var failedAt: Int?
    /// How many lines of the whole source come before this one's first.
    var lineOffset = 0

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
        let characters = Array(source.replacingOccurrences(of: "\r\n", with: "\n"))
        self.characters = characters
        self.lineStarts = [0] + characters.indices.filter { characters[$0] == "\n" }.map { $0 + 1 }
    }

    func unsupported(_ what: String, _ node: some SyntaxProtocol) -> SyntaxError {
        SyntaxError("\(what) isn't supported by this front end yet (line \(line(of: node)))")
    }

    func line(of node: some SyntaxProtocol) -> Int {
        line(atByte: node.positionAfterSkippingLeadingTrivia.utf8Offset)
    }

    /// The line a byte offset is on, in the whole source: a lowering of part
    /// of it (SwiftServices.swift) starts at a line of its own.
    func line(atByte offset: Int) -> Int {
        converter.location(for: AbsolutePosition(utf8Offset: offset)).line + lineOffset
    }

    // MARK: Programs

    mutating func program() throws -> Program {
        if plugin == nil, let refusal = LayerSyntaxFinder.first(in: tree) { throw SyntaxError("\(refusal.message) (line \(line(of: refusal.node)))") }
        for item in tree.statements { collectTypeNames(item.item) }
        // A SwiftParser tree that has problems has them in `unexpected` nodes
        // and missing tokens; the first one outside what the plug-in read is
        // the error, and comes before whatever else went wrong.
        let lowered: Program
        do {
            lowered = try block(tree.statements, scoped: false)
        } catch {
            if let layerError { throw layerError }
            // A problem in or before the statement that couldn't be lowered
            // explains it; one further on is in code not yet read, where the
            // plug-in's syntax may be.
            if let (problem, offset) = firstProblem(in: tree), offset <= failedEnd ?? Int.max { throw problem }
            throw error
        }
        if let (problem, _) = firstProblem(in: tree) { throw problem }
        if let problem = operatorProblems.first(where: { problem in !consumed.contains { $0.contains(problem.offset) } }) {
            throw SyntaxError("\(problem.message) (line \(line(atByte: problem.offset)))")
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
    func cursor(at byteOffset: Int) -> SourceCursor {
        var cursor = SourceCursor(chars: characters, scopes: [names()])
        cursor.plugin = plugin
        cursor.tryDepth = tryDepth
        cursor.functionDepth = leaving.function
        cursor.loopDepth = leaving.loop
        cursor.switchDepth = leaving.switchCase
        cursor.inAnonymousClosure = anonymous.last ?? false
        cursor.sawImport = sawImport
        cursor.context = context
        cursor.lineStarts = lineStarts
        cursor.lineOffset = lineOffset
        cursor.pos = characterOf[min(byteOffset, characterOf.count - 1)]
        return cursor
    }

    /// Where a cursor stopped, as a byte offset.
    func byteOffset(of parser: SourceCursor) -> Int {
        byteOf[min(parser.pos, byteOf.count - 1)]
    }

    /// Notes that the plug-in read from `start` to where its parser stopped.
    mutating func consume(from start: Int, to parser: SourceCursor) {
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
        // A block SwiftParser found no items in (`> out echo hi`, all of it unexpected
        // tokens to Swift) starts from where its text does.
        var islandEnd: Int? = items.isEmpty ? blockStart(items) : nil
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

    /// Where a block's statements start: after its `{`, or at the start of the source.
    private func blockStart(_ items: CodeBlockItemListSyntax) -> Int {
        if items.parent?.is(SourceFileSyntax.self) == true { return 0 }
        if let block = items.parent?.as(CodeBlockSyntax.self) { return block.leftBrace.endPositionBeforeTrailingTrivia.utf8Offset }
        if let closure = items.parent?.as(ClosureExprSyntax.self) {
            return (closure.signature?.endPositionBeforeTrailingTrivia ?? closure.leftBrace.endPositionBeforeTrailingTrivia).utf8Offset
        }
        return items.positionAfterSkippingLeadingTrivia.utf8Offset
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
            // Past blanks, comments and `;`, as the layer skips them.
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
            lines.append(line(atByte: at))
            skipUntil = island.end
        }
    }

    /// Where a node's text really ends, in bytes: SwiftParser can fold what
    /// follows a construct that isn't Swift's into its last item, as unexpected
    /// tokens, which aren't part of it.
    func realEnd(of node: some SyntaxProtocol) -> Int {
        var end = node.positionAfterSkippingLeadingTrivia.utf8Offset
        for token in node.tokens(viewMode: .sourceAccurate) where token.presence == .present {
            // Not inside what SwiftParser set aside as unexpected.
            var inside = false
            var parent = token.parent
            while let current = parent, current.id != node.id {
                if current.is(UnexpectedNodesSyntax.self) { inside = true; break }
                parent = current.parent
            }
            if !inside { end = max(end, token.endPositionBeforeTrailingTrivia.utf8Offset) }
        }
        return end
    }

    /// The first item of the source, which a reading of one construct starts at.
    func firstItem() throws -> CodeBlockItemSyntax {
        guard let item = tree.statements.first else {
            // Nothing to read: the input is blank (more could come), or only what Swift doesn't take.
            let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if let first = text.first { throw SyntaxError("unexpected '\(first)'") }
            throw SyntaxError.incomplete("expected something to read")
        }
        return item
    }

    /// One statement starting at the byte offset: the layer's, or Swift's, and
    /// where it ends; for the program in `$(…)`, read a statement at a time.
    mutating func readStatement(at start: Int) throws -> (statements: [Statement], end: Int) {
        if let island = try layerStatement(at: start, item: nil) { return ([island.statement], island.end) }
        let item = try firstItem()
        guard item.positionAfterSkippingLeadingTrivia.utf8Offset == start else { throw SyntaxError("expected a statement") }
        // The item's own `;`, missing where the next token doesn't separate statements, isn't one.
        let (lowered, end) = try reading(item.item) { try $0.statement(item.item) }
        return (lowered, end)
    }

    mutating func collectTypeNames(_ item: CodeBlockItemSyntax.Item) {
        if case .decl(let decl) = item {
            if let node = decl.as(StructDeclSyntax.self) { declaredTypes.insert(node.name.text) }
            if let node = decl.as(EnumDeclSyntax.self) { declaredTypes.insert(node.name.text) }
        }
    }

    /// The first problem SwiftParser found, and where (in bytes). `end` is where
    /// the input ends, for telling a problem of what's missing from one of what's there.
    func firstProblem(in tree: some SyntaxProtocol, end: AbsolutePosition? = nil) -> (SyntaxError, Int)? {
        let finder = ProblemFinder(end: end ?? tree.endPositionBeforeTrailingTrivia, consumed: consumed, accepted: accepted)
        finder.walk(tree)
        guard let (message, position) = finder.found else { return nil }
        let text = "\(message) (line \(line(atByte: position.utf8Offset)))"
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

    /// What is missing, as Swift's own messages say it: `expected 'else' after
    /// guard's condition, found '{'`.
    private func describeMissing(_ token: TokenSyntax) -> String {
        let name: String
        switch token.tokenKind {
        case .keyword(let keyword): name = "'\(keyword)'"
        case .leftParen: name = "'('"
        case .rightParen: name = "')'"
        case .leftBrace: name = "'{'"
        case .rightBrace: name = "'}'"
        case .leftSquare: name = "'['"
        case .rightSquare: name = "']'"
        case .comma: name = "','"
        case .colon: name = "':'"
        case .semicolon: name = "';'"
        case .equal: name = "'='"
        case .arrow: name = "'->'"
        case .identifier: name = "a name"
        default: name = "\(token.tokenKind)"
        }
        var message = "expected " + name
        var parent = token.parent
        while let current = parent {
            if current.is(GuardStmtSyntax.self), token.tokenKind == .keyword(.else) { message += " after guard's condition" }
            if current.is(CodeBlockItemSyntax.self) { break }
            parent = current.parent
        }
        if let next = token.nextToken(viewMode: .sourceAccurate), next.tokenKind != .endOfFile {
            message += ", found '\(next.text)'"
        }
        return message
    }

    /// Whether a missing token is in what the plug-in read: it is missing from
    /// a node that starts there, within its statement (`'a b'`, a string with
    /// its quotes missing to SwiftParser, at the end of a command).
    private func isInLayer(_ token: TokenSyntax) -> Bool {
        // A statement the layer read, right after one of Swift's on the same line, wants its `;`.
        if token.tokenKind == .semicolon, consumed.contains(where: { $0.lowerBound == token.position.utf8Offset }) { return false }
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
            found = (describeMissing(token), token.position)
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

/// With no layer plugged in, the constructs only a layer reads (`$(…)`, `$name`,
/// `async …`, `import Name from path`, a `|` between values) are refused by
/// name: SwiftParser's reading of them is its guess at text that isn't Swift.
private final class LayerSyntaxFinder: SyntaxVisitor {
    var found: (message: String, node: Syntax)?

    static func first(in tree: SourceFileSyntax) -> (message: String, node: Syntax)? {
        let finder = LayerSyntaxFinder(viewMode: .sourceAccurate)
        finder.walk(tree)
        return finder.found
    }

    private func refuse(_ message: String, _ node: some SyntaxProtocol) -> SyntaxVisitorContinueKind {
        if found == nil { found = (message, Syntax(node)) }
        return .skipChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let callee = node.calledExpression.as(DeclReferenceExprSyntax.self) else { return .visitChildren }
        switch callee.baseName.text {
        case "$": return refuse("$(…) runs commands, which are shell syntax, and isn't available in Swift-only code", node)
        case "async": return refuse("'async' starts a command in the background, which is shell syntax; Swift-only code has no async yet", node)
        default: return .visitChildren
        }
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        let name = node.baseName.text
        if name.hasPrefix("$"), name.count > 1, Int(name.dropFirst()) == nil {
            return refuse("$name reads the environment, which is shell syntax, and isn't available in Swift-only code", node)
        }
        if name == "async" { return refuse("'async' starts a command in the background, which is shell syntax; Swift-only code has no async yet", node) }
        return .visitChildren
    }

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        refuse("importing a package from a path is shell syntax, and isn't available in Swift-only code", node)
    }

    override func visit(_ node: InfixOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        if node.operator.as(BinaryOperatorExprSyntax.self)?.operator.text == "|" {
            return refuse("'|' pipes commands, which are shell syntax, and isn't an operator in Swift-only code", node)
        }
        return .visitChildren
    }
}
