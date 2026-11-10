import Foundation

// How a value prints: for the prompt, for `print` and as a literal.

extension Dictionary where Key == Swiit.Value {
    /// The entries sorted by key (`Value.displaysBefore`), so what's printed is the same every time.
    var sortedForDisplay: [(key: Key, value: Value)] {
        sorted { Key.displaysBefore($0.key, $1.key) }.map { (key: $0.key, value: $0.value) }
    }
}

extension Value {
    /// The order a dictionary's keys are shown in: only for showing, so it
    /// needn't mean anything beyond being the same every time.
    static func displaysBefore(_ a: Value, _ b: Value) -> Bool {
        switch (a.storage, b.storage) {
        case (.int(let x), .int(let y)): return x < y
        case (.int, .double), (.double, .int), (.double, .double):
            return a.displayNumber! < b.displayNumber!
        case (.string(let x), .string(let y)): return x < y
        case (.bool(let x), .bool(let y)): return !x && y
        case (.enumValue(let x), .enumValue(let y)) where x.type === y.type && x.index != y.index:
            return x.index < y.index
        default:
            return a.debugDescription < b.debugDescription
        }
    }

    private var displayNumber: Double? {
        switch self.storage {
        case .int(let n): Double(n)
        case .double(let d): d
        default: nil
        }
    }
}

extension Value: CustomStringConvertible {
    public var description: String {
        switch self.storage {
        case .nothing: ""
        case .bool(let value): String(value)
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .string(let value): value
        case .list(let values): "[" + values.map(\.description).joined(separator: ", ") + "]"
        case .tuple(let tuple): tuple.description
        case .structure(let structure): structure.description
        case .dictionary(let dictionary): dictionary.description
        case .enumValue(let value): value.description
        case .object(let object): object.description
        case .function(let function): function.description
        }
    }
}

extension Value {
    /// A string as a literal: quotes, backslashes and control characters
    /// escaped. Like Swift's `debugDescription`, but a `'` stays as it is.
    static func quoted(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                result += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}

extension Value: CustomDebugStringConvertible {
    /// As Swift's `debugPrint` shows it, and as the prompt shows a bare
    /// value: strings quoted, cases with their type, outputs and records
    /// with their fields.
    public var debugDescription: String {
        switch self.storage {
        case .nothing: "nil"
        case .string(let value): Value.quoted(value)
        case .list(let values): "[" + values.map(\.debugDescription).joined(separator: ", ") + "]"
        case .tuple(let tuple): tuple.debugDescription
        case .structure(let structure): structure.debugDescription
        case .dictionary(let dictionary): dictionary.debugDescription
        case .enumValue(let value): value.debugDescription
        case .object(let object): object.debugDescription
        default: description
        }
    }
}
