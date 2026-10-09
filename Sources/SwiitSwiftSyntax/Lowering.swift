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
    /// The first problem found, since SwiftSyntax's visitors don't throw.
    var failure: SyntaxError?

    init(source: String, tree: SourceFileSyntax, bound: [String: NameKind]) {
        self.converter = SourceLocationConverter(fileName: "", tree: tree)
        self.tree = tree
        self.bound = bound
    }

    func unsupported(_ what: String, _ node: some SyntaxProtocol) -> SyntaxError {
        SyntaxError("\(what) isn't supported by this front end yet (line \(line(of: node)))")
    }

    func line(of node: some SyntaxProtocol) -> Int {
        converter.location(for: node.positionAfterSkippingLeadingTrivia).line
    }

    // MARK: Programs

    mutating func program() throws -> Program {
        // A SwiftParser tree that has problems has them in `unexpected` nodes
        // and missing tokens; the first one is the error.
        if let problem = firstProblem(in: tree) { throw problem }
        for item in tree.statements { collectTypeNames(item.item) }
        return try block(tree.statements, scoped: false)
    }

    mutating func block(_ items: CodeBlockItemListSyntax, scoped: Bool = true) throws -> Program {
        if scoped { locals.append([]) }
        defer { if scoped { locals.removeLast() } }
        var statements: [Statement] = []
        var lines: [Int] = []
        for item in items {
            let lowered = try statement(item.item)
            lines += [line(of: item)] + Array(repeating: line(of: item), count: max(lowered.count - 1, 0))
            statements += lowered
        }
        return Program(statements: statements, lines: lines)
    }

    mutating func collectTypeNames(_ item: CodeBlockItemSyntax.Item) {
        if case .decl(let decl) = item {
            if let node = decl.as(StructDeclSyntax.self) { declaredTypes.insert(node.name.text) }
            if let node = decl.as(EnumDeclSyntax.self) { declaredTypes.insert(node.name.text) }
        }
    }

    func firstProblem(in tree: some SyntaxProtocol) -> SyntaxError? {
        let finder = ProblemFinder(end: tree.endPositionBeforeTrailingTrivia)
        finder.walk(tree)
        guard let (message, position) = finder.found else { return nil }
        let line = converter.location(for: position).line
        let text = "\(message) (line \(line))"
        return finder.incomplete ? .incomplete(text) : SyntaxError(text)
    }
}

private final class ProblemFinder: SyntaxVisitor {
    var found: (String, AbsolutePosition)?
    var incomplete = false
    let end: AbsolutePosition
    init(end: AbsolutePosition) {
        self.end = end
        super.init(viewMode: .all)
    }
    override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
        if found == nil, token.presence == .missing {
            found = ("expected \(token.tokenKind)", token.position)
            if token.position >= end { incomplete = true }
        }
        return .skipChildren
    }
    override func visit(_ node: UnexpectedNodesSyntax) -> SyntaxVisitorContinueKind {
        if found == nil { found = ("unexpected '\(node.trimmedDescription)'", node.position) }
        return .skipChildren
    }
}
