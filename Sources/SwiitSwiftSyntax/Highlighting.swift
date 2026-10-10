@_spi(Shell) import Swiit
import SwiftSyntax
import SwishKit

/// Highlighting from SwiftParser's tree: each token's kind, from what it is
/// and where it stands, and the spans the plug-in recorded where it read the
/// layer's syntax. Half-typed input has a tree too, so a line is colored as
/// it is typed.
extension Lowering {
    /// The spans of the source, in characters, as the hand parser records them.
    func highlightSpans() -> [Span] {
        let classifier = TokenClassifier(consumed: consumed)
        classifier.walk(tree)
        let swift = classifier.spans.compactMap { span -> Span? in
            let start = characterOf[min(span.range.lowerBound, characterOf.count - 1)]
            let end = characterOf[min(span.range.upperBound, characterOf.count - 1)]
            return start < end ? Span(range: start..<end, kind: span.kind) : nil
        }
        return swift + layerSpans
    }
}

/// Spans in bytes, for the tokens outside what the plug-in read.
private final class TokenClassifier: SyntaxVisitor {
    var spans: [Span] = []
    let consumed: [Range<Int>]

    init(consumed: [Range<Int>]) {
        self.consumed = consumed
        super.init(viewMode: .sourceAccurate)
    }

    private func isConsumed(_ offset: Int) -> Bool {
        consumed.contains { $0.contains(offset) }
    }

    private func add(_ kind: SpanKind, _ node: some SyntaxProtocol) {
        let start = node.positionAfterSkippingLeadingTrivia.utf8Offset
        guard !isConsumed(start) else { return }
        spans.append(Span(range: start..<node.endPositionBeforeTrailingTrivia.utf8Offset, kind: kind))
    }

    // `\.size.bytes` is one name, as the hand parser reads it.
    override func visit(_ node: KeyPathExprSyntax) -> SyntaxVisitorContinueKind {
        add(.variable, node)
        return .skipChildren
    }

    // `@flag("n")`: the attribute is a keyword, its letter a string.
    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
        let start = node.atSign.positionAfterSkippingLeadingTrivia.utf8Offset
        if !isConsumed(start) {
            spans.append(Span(range: start..<node.attributeName.endPositionBeforeTrailingTrivia.utf8Offset, kind: .keyword))
        }
        if let arguments = node.arguments { walk(arguments) }
        return .skipChildren
    }

    // A string is a string throughout, with what is interpolated painted over it.
    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        add(.string, node)
        return .visitChildren
    }

    // `#filePath`
    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        add(.keyword, node)
        return .skipChildren
    }

    // `try?` and `try!`, mark and all.
    override func visit(_ node: TryExprSyntax) -> SyntaxVisitorContinueKind {
        let start = node.tryKeyword.positionAfterSkippingLeadingTrivia.utf8Offset
        if !isConsumed(start) {
            let end = (node.questionOrExclamationMark ?? node.tryKeyword).endPositionBeforeTrailingTrivia.utf8Offset
            spans.append(Span(range: start..<end, kind: .keyword))
        }
        walk(node.expression)
        return .skipChildren
    }

    // `as?` and `as!`, mark and all.
    override func visit(_ node: AsExprSyntax) -> SyntaxVisitorContinueKind {
        let start = node.asKeyword.positionAfterSkippingLeadingTrivia.utf8Offset
        if !isConsumed(start) {
            let end = (node.questionOrExclamationMark ?? node.asKeyword).endPositionBeforeTrailingTrivia.utf8Offset
            spans.append(Span(range: start..<end, kind: .keyword))
        }
        walk(node.expression)
        walk(node.type)
        return .skipChildren
    }

    // `.directory`: a case, dot and all; `2.mb`, a file size, is a number.
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if let base = node.base, FileSize.units[node.declName.baseName.text] != nil,
           base.is(IntegerLiteralExprSyntax.self) || base.is(FloatLiteralExprSyntax.self) {
            add(.number, node)
            return .skipChildren
        }
        if node.base == nil {
            let start = node.period.positionAfterSkippingLeadingTrivia.utf8Offset
            if !isConsumed(start) {
                spans.append(Span(range: start..<node.declName.endPositionBeforeTrailingTrivia.utf8Offset, kind: .constant))
            }
        }
        return .visitChildren
    }

    override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
        for comment in comments(token.leadingTrivia, from: token.position.utf8Offset) { spans.append(comment) }
        if let kind = kind(of: token) { add(kind, token) }
        let trailing = token.endPositionBeforeTrailingTrivia.utf8Offset
        for comment in comments(token.trailingTrivia, from: trailing) { spans.append(comment) }
        return .skipChildren
    }

    private func comments(_ trivia: Trivia, from start: Int) -> [Span] {
        var offset = start
        var found: [Span] = []
        for piece in trivia {
            let length = piece.sourceLength.utf8Length
            switch piece {
            case .lineComment, .blockComment, .docLineComment, .docBlockComment:
                if !isConsumed(offset) { found.append(Span(range: offset..<offset + length, kind: .comment)) }
            default: break
            }
            offset += length
        }
        return found
    }

    private func kind(of token: TokenSyntax) -> SpanKind? {
        let parent = token.parent
        switch token.tokenKind {
        case .keyword(.true), .keyword(.false), .keyword(.nil):
            return .constant
        case .keyword(.self):
            return .variable
        case .keyword(.Self), .keyword(.Any) where parent?.is(IdentifierTypeSyntax.self) == true:
            return .type
        case .keyword(.try):
            return nil
        case .keyword(.`init`) where parent?.is(DeclReferenceExprSyntax.self) == true:
            return nil
        case .keyword:
            // A keyword used as a label (`f(in: x)`) or a member name is a name.
            if parent?.is(LabeledExprSyntax.self) == true || parent?.is(FunctionParameterSyntax.self) == true { return nil }
            return .keyword
        case .stringQuote, .multilineStringQuote, .stringSegment, .singleQuote, .rawStringPoundDelimiter:
            return .string
        case .backslash, .leftParen, .rightParen:
            return parent?.is(ExpressionSegmentSyntax.self) == true ? .punctuation : nil
        case .integerLiteral, .floatLiteral:
            // `t.1` is a member, plain as other members are.
            return parent?.is(DeclReferenceExprSyntax.self) == true ? nil : .number
        case .binaryOperator(let text) where ["+=", "-=", "*=", "/="].contains(text):
            return .punctuation
        case .pound, .poundSourceLocation:
            return nil
        case .wildcard where parent?.is(WildcardPatternSyntax.self) == true && parent?.parent?.is(ForStmtSyntax.self) == true:
            // `for _ in …`: the loop's variable, unnamed.
            return .variable
        case .identifier, .dollarIdentifier:
            return kind(ofName: token, parent: parent)
        default:
            return nil
        }
    }

    private func kind(ofName token: TokenSyntax, parent: Syntax?) -> SpanKind? {
        guard let parent else { return nil }
        if let reference = parent.as(DeclReferenceExprSyntax.self) {
            // `a.name` is the member's, which the hand parser leaves plain;
            // `.name` alone is a case.
            if let access = reference.parent?.as(MemberAccessExprSyntax.self), access.declName.id == reference.id {
                return nil
            }
            if reference.parent?.is(MacroExpansionExprSyntax.self) == true { return .keyword }
            return .variable
        }
        if parent.is(IdentifierTypeSyntax.self) || parent.is(MemberTypeSyntax.self) { return .type }
        if parent.is(StructDeclSyntax.self) || parent.is(EnumDeclSyntax.self) { return .type }
        if parent.is(FunctionDeclSyntax.self) { return .command }
        if parent.is(EnumCaseElementSyntax.self) { return .constant }
        if parent.is(IdentifierPatternSyntax.self) { return .variable }
        // A parameter's names are left plain, as the hand parser leaves them.
        if parent.is(FunctionParameterSyntax.self) { return nil }
        if parent.is(MacroExpansionExprSyntax.self) { return .keyword }
        return nil
    }
}
