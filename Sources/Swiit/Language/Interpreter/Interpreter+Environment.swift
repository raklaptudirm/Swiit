import Foundation
import SwiitKit
import SwiitStandardLibrary

extension Interpreter {
    /// Joins a string's parts into one string. Interpolation never splits.
    func expand(_ parts: [StringPart]) throws -> String {
        try parts.map { part in
            switch part {
            case .literal(let text): text
            case .expression(let expr): try evaluate(expr).description
            }
        }.joined()
    }
}
