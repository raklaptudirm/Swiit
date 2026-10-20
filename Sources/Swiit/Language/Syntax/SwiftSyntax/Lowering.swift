import Foundation
import SwiftOperators
import SwiftSyntax

/// Lowers SwiftParser's tree to the core's. A construct it doesn't lower is a
/// `SyntaxError` that names it, so the supported subset is the set of nodes
/// handled here.
/// How the type around a declaration names things, kept to restore when its body ends: the qualified name its
/// members are declared under, the type that `Self` is, and the short names of the types declared inside it.
struct EnclosingType {
    var prefix: String
    var current: String?
    var nested: [String: String]
}

struct Lowering {
    let converter: SourceLocationConverter
    let tree: SourceFileSyntax
    let bound: [String: NameKind]
    /// Struct, enum and typealias names declared by the program, which a type
    /// may name before they are declared.
    var declaredTypes: Set<String> = []
    /// What the declarations say about those types and the variables around them.
    var facts = DeclarationFacts()
    /// The names bound by the blocks around the code being lowered, innermost
    /// last: a parameter, a `let`, a loop variable, a pattern's binding.
    var locals: [Set<String>] = [[]]
    /// The members of the struct whose body this is, innermost last, which a
    /// bare name in a method reads through `self`.
    var members: [Set<String>] = []
    /// While a static member is lowered: its type and the static members a
    /// bare name there reads through the type's name.
    var staticContext: (owner: String, names: Set<String>)?
    /// The function names declared so far, the names of the program.
    var functions: Set<String> = []
    /// How many `try`s cover the code being lowered, which makes a `$(…)` or an
    /// `await` throw; a function's or closure's body starts afresh.
    var tryDepth = 0
    /// What a `return`, `break`, `continue` or `fallthrough` here can leave.
    var leaving = Leaving()
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
    /// Nodes SwiftParser found something missing in that the core reads as
    /// they are, as a bare `await`.
    var accepted: Set<SyntaxIdentifier> = []
    /// What folding operators found wrong, and where (in bytes): a problem only
    /// outside what the front end read.
    var operatorProblems: [(message: String, offset: Int)] = []
    /// Whether to go on past a statement that can't be read, as highlighting
    /// a line half typed does, rather than stop at it.
    var recovering = false
    /// The end of the innermost statement that couldn't be lowered (in bytes).
    var failedEnd: Int?
    /// Reading the prelude, the builtins' declarations (Prelude.swift): a
    /// function without a body has one in Swift, and `extension Sequence`
    /// declares the methods every sequence has.
    var prelude = false
    /// The closures around the code being lowered, innermost last: whether
    /// each takes `$0`, `$1`, … (one without named parameters does).
    var anonymous: [Bool] = []
    /// `typealias Name = Type`, which a type written as `Name` stands for.
    var aliases: [String: TypeAnnotation] = [:]
    /// The functions around the code being lowered, innermost last, as `#function` names them.
    var functionNames: [String] = []
    /// `o?.a.b`: the name the chain's `o?` is read by inside the closure that runs the rest of it.
    var chainPlaceholders: [SyntaxIdentifier: String] = [:]
    var chainCount = 0
    /// The expressions of the statement being lowered, and where each is.
    var currentSpots: [Spot] = []
    var recordsSpots = true
    /// Inside a type: its name with the types around it (`Outer.Inner`), what `Self` is,
    /// the types declared in it by the short name they go by there, and those
    /// lowered but not yet put in the program (they come before the type holding them).
    var typePrefix = ""
    var currentType: String?
    var nestedNames: [String: String] = [:]
    /// In an extension of a collection, the names its items go by (`Element`).
    var typeParameters: Set<String> = []
    var pendingNested: [Statement] = []
    /// How many tuples `let (a, b) = …` has held, for their names.
    var destructurings = 0
    /// Where the last error was, in bytes, for the cursor that asked.
    var failedAt: Int?
    /// How many lines of the whole source come before this one's first.
    var lineOffset = 0

    init(source: String, tree: SourceFileSyntax, bound: [String: NameKind]) {
        self.converter = SourceLocationConverter(fileName: "", tree: tree)
        self.tree = tree
        self.bound = bound
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
        SyntaxError("\(what) isn't supported by this front end yet (line \(line(of: node)))", range: range(of: node))
    }

    func line(of node: some SyntaxProtocol) -> Int {
        line(atByte: node.positionAfterSkippingLeadingTrivia.utf8Offset)
    }

    /// Where a node is, from the start of its text to the end of it.
    func range(of node: some SyntaxProtocol) -> SourceRange {
        range(fromByte: node.positionAfterSkippingLeadingTrivia.utf8Offset, toByte: node.endPositionBeforeTrailingTrivia.utf8Offset)
    }

    /// Where bytes are: lines and columns in characters.
    func range(fromByte start: Int, toByte end: Int) -> SourceRange {
        func place(_ byte: Int) -> (line: Int, column: Int) {
            let character = characterOf[max(0, min(byte, characterOf.count - 1))]
            var low = 0, high = lineStarts.count
            while low + 1 < high {
                let middle = (low + high) / 2
                if lineStarts[middle] <= character { low = middle } else { high = middle }
            }
            return (low + 1 + lineOffset, character - lineStarts[low] + 1)
        }
        let from = place(start), to = place(max(start, end))
        return SourceRange(startLine: from.line, startColumn: from.column, endLine: to.line, endColumn: to.column)
    }

    /// The line a byte offset is on, in the whole source.
    func line(atByte offset: Int) -> Int {
        converter.location(for: AbsolutePosition(utf8Offset: offset)).line + lineOffset
    }

    // MARK: Programs

    mutating func program() throws -> Program {
        for item in tree.statements { collectTypeNames(item.item) }
        // A SwiftParser tree that has problems has them in `unexpected` nodes
        // and missing tokens; the first one is the error, and comes
        // before whatever else went wrong.
        let lowered: Program
        do {
            lowered = try block(tree.statements, scoped: false)
        } catch {
            // A problem in or before the statement that couldn't be lowered
            // explains it; one further on is in code not yet read.
            if let (problem, offset) = firstProblem(in: tree), offset <= failedEnd ?? Int.max { throw problem }
            throw error
        }
        if let (problem, _) = firstProblem(in: tree) { throw problem }
        if let problem = operatorProblems.first {
            throw SyntaxError("\(problem.message) (line \(line(atByte: problem.offset)))",
                              range: range(fromByte: problem.offset, toByte: min(problem.offset + 1, bytes.count)))
        }
        return lowered
    }

    // MARK: Names

    /// The names the code being lowered has bound, and what each is.
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

    mutating func block(_ items: CodeBlockItemListSyntax, scoped: Bool = true) throws -> Program {
        if scoped { locals.append([]) }
        defer { if scoped { locals.removeLast() } }
        // Functions can be called before their declarations, as in Swift.
        for item in items {
            if case .decl(let decl) = item.item, let function = decl.as(FunctionDeclSyntax.self) { functions.insert(function.name.text) }
        }
        var statements: [Statement] = []
        var lines: [Int] = []
        var ranges: [SourceRange] = []
        var spots: [[Spot]] = []
        for item in items {
            let lowered: [Statement]
            let outerSpots = currentSpots
            currentSpots = []
            defer { currentSpots = outerSpots }
            do {
                lowered = try statement(item.item)
            } catch where recovering {
                continue
            } catch {
                failedEnd = failedEnd ?? item.endPosition.utf8Offset
                throw error
            }
            let itemSpots = currentSpots
            currentSpots = outerSpots
            lines += [line(of: item)] + Array(repeating: line(of: item), count: max(lowered.count - 1, 0))
            ranges += Array(repeating: range(of: item), count: lowered.count)
            spots += Array(repeating: itemSpots, count: lowered.count)
            statements += lowered
        }
        return Program(statements: statements, lines: lines, ranges: ranges, spots: spots)
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

    mutating func collectTypeNames(_ item: CodeBlockItemSyntax.Item) {
        guard case .decl(let decl) = item else { return }
        collectTypeNames(decl, prefix: "")
        // An operator declared in the program can be used before its declaration, as any function can.
        if let node = decl.as(FunctionDeclSyntax.self), let first = node.name.text.first, !(first.isLetter || first == "_") {
            functions.insert(node.name.text)
        }
    }

    /// A type's name, and the names of the types declared inside it.
    private mutating func collectTypeNames(_ decl: DeclSyntax, prefix: String) {
        let block: MemberBlockSyntax
        let name: String
        if let node = decl.as(StructDeclSyntax.self) { name = prefix + node.name.text; block = node.memberBlock }
        else if let node = decl.as(EnumDeclSyntax.self) { name = prefix + node.name.text; block = node.memberBlock }
        else if let node = decl.as(ProtocolDeclSyntax.self) { name = prefix + node.name.text; block = node.memberBlock }
        else if let node = decl.as(ClassDeclSyntax.self) { name = prefix + node.name.text; block = node.memberBlock }
        else if let node = decl.as(ActorDeclSyntax.self) { name = prefix + node.name.text; block = node.memberBlock }
        else { return }
        declaredTypes.insert(name)
        if decl.is(ProtocolDeclSyntax.self) { facts.protocols.insert(name) }
        // A class's members, and its superclass, for a subclass's bodies to name what it inherits.
        if let node = decl.as(ClassDeclSyntax.self) {
            if let first = node.inheritanceClause?.inheritedTypes.first { facts.superclass[name] = first.type.trimmedDescription }
            for member in block.members {
                if let variable = member.decl.as(VariableDeclSyntax.self), !isStatic(variable.modifiers) {
                    for binding in variable.bindings {
                        if let identifier = binding.pattern.as(IdentifierPatternSyntax.self) { facts.instanceMembers[name, default: []].insert(identifier.identifier.text) }
                    }
                }
                if let method = member.decl.as(FunctionDeclSyntax.self), !isStatic(method.modifiers) { facts.instanceMembers[name, default: []].insert(method.name.text) }
            }
        }
        // A result builder: its name, and the functions it has.
        let attributes = decl.as(StructDeclSyntax.self)?.attributes ?? decl.as(EnumDeclSyntax.self)?.attributes
            ?? decl.as(ClassDeclSyntax.self)?.attributes
        if attributes?.contains(where: { attribute in
            if case .attribute(let named) = attribute { return named.attributeName.trimmedDescription == "resultBuilder" }
            return false
        }) == true {
            facts.resultBuilders.insert(name)
        }
        // A generic enum keeps its type arguments, which say what its cases hold.
        if let node = decl.as(EnumDeclSyntax.self), node.genericParameterClause != nil { facts.genericEnums.insert(name) }
        for member in block.members { collectTypeNames(member.decl, prefix: name + ".") }
    }

    /// The first problem SwiftParser found, and where (in bytes). `end` is where
    /// the input ends, for telling a problem of what's missing from one of what's there.
    func firstProblem(in tree: some SyntaxProtocol, end: AbsolutePosition? = nil) -> (SyntaxError, Int)? {
        let finder = ProblemFinder(end: end ?? tree.endPositionBeforeTrailingTrivia, accepted: accepted)
        finder.walk(tree)
        guard let (message, position) = finder.found else { return nil }
        let text = "\(message) (line \(line(atByte: position.utf8Offset)))"
        // A problem is at a token: one character is what is known of it.
        let place = range(fromByte: position.utf8Offset, toByte: min(position.utf8Offset + 1, bytes.count))
        return (finder.incomplete ? SyntaxError(text, incomplete: true, range: place) : SyntaxError(text, range: place), position.utf8Offset)
    }
}

/// How many functions, loops and switch cases are around the code being
/// lowered: nothing leaves a `defer`, and a function's body leaves only it.
struct Leaving {
    var function = 0
    var loop = 0
    var switchCase = 0
    /// The labels of the loops around, which `break label` and `continue label` name.
    var labels: [String] = []
}

private final class ProblemFinder: SyntaxVisitor {
    var found: (String, AbsolutePosition)?
    var incomplete = false
    let end: AbsolutePosition
    let accepted: Set<SyntaxIdentifier>
    init(end: AbsolutePosition, accepted: Set<SyntaxIdentifier>) {
        self.end = end
        self.accepted = accepted
        super.init(viewMode: .all)
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

    /// Whether a missing token is one the core reads as it is (a bare `await`).
    private func isAccepted(_ token: TokenSyntax) -> Bool {
        var node = token.parent
        while let current = node {
            if accepted.contains(current.id) { return true }
            if current.is(CodeBlockItemSyntax.self) || current.is(MemberBlockItemSyntax.self) { return false }
            node = current.parent
        }
        return false
    }
    override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
        if found == nil, token.presence == .missing, !isAccepted(token) {
            found = (describeMissing(token), token.position)
            // At the end of the text, or with only blanks and comments after it (a window cut after a blank line):
            // the construct isn't finished, and a longer window may finish it.
            if token.position >= end || token.nextToken(viewMode: .sourceAccurate).map({ $0.tokenKind == .endOfFile }) ?? true {
                incomplete = true
            }
        }
        return .skipChildren
    }
    override func visit(_ node: UnexpectedNodesSyntax) -> SyntaxVisitorContinueKind {
        if found == nil, node.parent.map({ accepted.contains($0.id) }) != true {
            found = ("unexpected '\(node.trimmedDescription)'", node.position)
        }
        return .skipChildren
    }
}
