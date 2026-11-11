import Foundation
import SwiftSyntax

extension SourceRange {
    /// The whole of one line, when nothing narrower is known.
    init(line: Int) {
        let place = SourceLocation(line: line, column: 1, offset: 0, file: "")
        self.init(start: place, end: place)
    }
}

/// An expression of a statement and where it was written: what an error in it points at.
struct Spot: Equatable, Sendable {
    var expression: Expr
    var range: SourceRange
}
