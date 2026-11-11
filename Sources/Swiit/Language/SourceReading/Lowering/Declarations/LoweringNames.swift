import SwiftSyntax

// The names a syntax node refers to.

extension Lowering {
    /// The names a body mentions, so a closure keeps only the variables it uses.
    func names(in node: some SyntaxProtocol) -> Set<String> {
        let collector = NameCollector()
        collector.walk(node)
        var names = collector.names
        return names
    }
}

private final class NameCollector: SyntaxVisitor {
    var names: Set<String> = []
    init() { super.init(viewMode: .sourceAccurate) }
    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.baseName.text)
        return .visitChildren
    }
    /// A type named in the body (`x as? T`) counts as a name used, for a type parameter's sake.
    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.name.text)
        return .visitChildren
    }
}
