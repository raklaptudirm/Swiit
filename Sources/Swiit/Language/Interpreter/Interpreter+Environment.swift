import Foundation
import SwiitKit
import SwiitStandardLibrary

extension Interpreter {
    /// Joins a string's parts into one string. Interpolation never splits.
    func expand(_ parts: [StringPart]) throws -> String {
        try parts.map { part in
            switch part {
            case .literal(let text): text
            case .expression(let expr): try describing(try evaluate(expr))
            }
        }.joined()
    }

    /// What `print` and interpolation show, as Swift does: a String as it is,
    /// a struct by its `description` if it says it's a CustomStringConvertible
    /// (and its `debugDescription` for `debug`, in a collection or a tuple),
    /// and anything inside a collection the way `debugPrint` shows it, so a
    /// text in an array has its quotes.
    func describing(_ value: Value, debug: Bool = false) throws -> String {
        switch value {
        case .string(let text):
            return debug ? value.debugDescription : text
        case .list(let items):
            return "[" + (try items.map { try describing($0, debug: true) }).joined(separator: ", ") + "]"
        case .dictionary(let dictionary):
            guard dictionary.count > 0 else { return "[:]" }
            return "[" + (try dictionary.sortedForDisplay.map {
                "\(try describing($0.key, debug: true)): \(try describing($0.value, debug: true))"
            }).joined(separator: ", ") + "]"
        case .record(let record):
            if let type = structType(of: record) {
                if debug, type.conformances.contains("CustomDebugStringConvertible"), let text = try structMember("debugDescription", of: record, type) {
                    return try describing(text)
                }
                if type.conformances.contains("CustomStringConvertible"), let text = try structMember("description", of: record, type) {
                    return try describing(text)
                }
            }
            return (record.typeName ?? "") + "(" + (try record.map { field in
                (Record.isPosition(field.key) ? "" : "\(field.key): ") + (try describing(field.value, debug: true))
            }).joined(separator: ", ") + ")"
        default:
            return debug ? value.debugDescription : value.description
        }
    }
}
