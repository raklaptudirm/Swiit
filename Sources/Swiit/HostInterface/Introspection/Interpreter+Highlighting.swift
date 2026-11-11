import Foundation
import SwiftSyntax
import Synchronization

// Highlighting source by what each part is.

extension Interpreter {
    /// How to color Swift source, in characters, which may be half typed: what it reads before a
    /// problem is colored as it reads it.
    public func highlighting(_ source: String) -> [Highlight] {
        let bound = withMainTask { globalNames() }
        return frontEnd.highlight(source, bound: bound)
            .map { span in
                let kind: Highlight.Kind =
                    switch span.kind {
                    case .keyword: .keyword
                    case .function: .function
                    case .string: .string
                    case .number: .number
                    case .constant: .constant
                    case .variable: .variable
                    case .comment: .comment
                    case .type: .type
                    case .punctuation: .punctuation
                    }
                return Highlight(range: span.range, kind: kind)
            }
    }

    /// A stretch of source and what it is.
    public struct Highlight: Sendable {
        public enum Kind: Sendable {
            case keyword, function, string, number, constant, variable, comment, type, punctuation
        }
        public var range: Range<Int>
        public var kind: Kind
    }
}
