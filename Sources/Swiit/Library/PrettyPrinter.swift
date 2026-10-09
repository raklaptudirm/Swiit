import Foundation
import SwishKit

/// Shows a value as `debugDescription` spells it, but for a person: in the
/// highlighter's colors, and, when it won't fit on one line, broken over
/// lines with each element or field on its own, the way you'd format it as
/// Swift. A string of several lines is a `"""` literal then.
public struct PrettyPrinter: Sendable {
    public var width = 80
    public var styled = false

    public init(width: Int = 80, styled: Bool = false) {
        self.width = width
        self.styled = styled
    }

    typealias Segment = DisplaySegment

    /// A value's shape: text that can't be broken, a string, or brackets
    /// around (labeled) elements.
    indirect enum Node {
        case segments([Segment])
        case string(String)
        case group(open: [Segment], items: [(label: [Segment], node: Node)], close: String)
    }

    public func format(_ value: Value) -> String {
        render(node(for: value), indent: 0, used: 0, trailing: 0)
    }

    // MARK: Shapes

    func node(for value: Value) -> Node {
        switch value {
        case .nothing: .segments([("nil", DisplayStyle.constant)])
        case .bool, .int, .double: .segments([(value.description, DisplayStyle.constant)])
        case .function: .segments([(value.description, nil)])
        case .string(let text): .string(text)
        case .list(let items):
            .group(open: [("[", nil)], items: items.map { ([], node(for: $0)) }, close: "]")
        case .record(let record): node(for: record)
        case .dictionary(let dictionary):
            dictionary.count == 0 ? .segments([("[:]", nil)]) : .group(open: [("[", nil)], items: dictionary.sortedForDisplay.map { key, value in
                ([keySegment(key), (": ", nil)], node(for: value))
            }, close: "]")
        // A Swift value as its type says it looks: as fields, or in a style.
        case .object where value.displayShape.fields != nil || value.displayShape.role != nil:
            value.displayShape.fields.map { node(for: $0) } ?? .segments([(value.description, value.displayShape.role)])
        case .enumValue(let value):
            node(for: value)
        case .object(let object) where object.displaySegments != nil:
            .segments(object.displaySegments!)
        case .object(let type as EnumType):
            .segments([("enum", DisplayStyle.keyword), (" ", nil), (type.name, DisplayStyle.type)])
        case .object(let object):
            object.fields.map { node(for: $0) } ?? .segments([(object.debugDescription, nil)])
        @unknown default:
            .segments([(value.debugDescription, nil)])
        }
    }

    /// A struct's value, `Point(x: 1)`, or a tuple, `(name: "x", 2)`.
    private func node(for record: Record) -> Node {
        let open: [Segment] = record.typeName.map { [($0, DisplayStyle.type), ("(", nil)] } ?? [("(", nil)]
        return .group(open: open, items: record.map { field in
            (Record.isPosition(field.key) ? [] : label(field.key), node(for: field.value))
        }, close: ")")
    }

    private func keySegment(_ key: Value) -> Segment {
        if case .string(let text) = key { return (Value.quoted(text), DisplayStyle.string) }
        return (key.debugDescription, DisplayStyle.constant)
    }

    private func node(for value: EnumValue) -> Node {
        let head: [Segment] = [(value.type.name, DisplayStyle.type), ("." + value.name, nil)]
        guard !value.values.isEmpty else { return .segments(head) }
        let labels = value.definition?.labels ?? []
        let items = value.values.enumerated().map { index, item in
            (index < labels.count ? labels[index].map(label) ?? [] : [], node(for: item))
        }
        return .group(open: head + [("(", nil)], items: items, close: ")")
    }

    private func label(_ name: String) -> [Segment] {
        [(name + ": ", nil)]
    }

    // MARK: Layout

    /// `node` starting `used` columns into a line indented by `indent`, with
    /// `trailing` columns (a comma) to follow it.
    private func render(_ node: Node, indent: Int, used: Int, trailing: Int) -> String {
        let line = flat(node)
        if !mustBreak(node, indent: indent), used + line.plain.count + trailing <= width { return line.styled }
        switch node {
        case .segments:
            return line.styled // Can't be broken.
        case .string(let text):
            guard text.contains("\n") else { return line.styled }
            let inner = String(repeating: " ", count: indent + 2)
            let body = text.split(separator: "\n", omittingEmptySubsequences: false).map { row in
                row.isEmpty ? "" : inner + PrettyPrinter.escapedForBlock(String(row)).styled(DisplayStyle.string, styled)
            }
            let quotes = "\"\"\"".styled(DisplayStyle.string, styled)
            return quotes + "\n" + body.joined(separator: "\n") + "\n" + inner + quotes
        case .group(let open, let items, let close):
            guard !items.isEmpty else { return line.styled }
            let inner = String(repeating: " ", count: indent + 2)
            let rows = items.enumerated().map { index, item in
                let isLast = index == items.count - 1
                let label = paint(item.label)
                return inner + label.styled
                    + render(item.node, indent: indent + 2, used: indent + 2 + label.plain.count, trailing: isLast ? 0 : 1)
                    + (isLast ? "" : ",")
            }
            return paint(open).styled + "\n" + rows.joined(separator: "\n") + "\n"
                + String(repeating: " ", count: indent) + close
        }
    }

    /// A string of several lines inside something is a `"""` block, so
    /// command output reads as it printed; what holds one breaks for it.
    private func mustBreak(_ node: Node, indent: Int) -> Bool {
        switch node {
        case .segments: false
        case .string(let text): indent > 0 && text.contains("\n")
        case .group(_, let items, _): items.contains { mustBreak($0.node, indent: 1) }
        }
    }

    /// The one-line form: exactly `debugDescription`, when plain.
    private func flat(_ node: Node) -> (plain: String, styled: String) {
        switch node {
        case .segments(let segments):
            return paint(segments)
        case .string(let text):
            let quoted = Value.quoted(text)
            return (quoted, quoted.styled(DisplayStyle.string, styled))
        case .group(let open, let items, let close):
            var plain = paint(open).plain
            var colored = paint(open).styled
            for (index, item) in items.enumerated() {
                if index > 0 {
                    plain += ", "
                    colored += ", "
                }
                let label = paint(item.label)
                let value = flat(item.node)
                plain += label.plain + value.plain
                colored += label.styled + value.styled
            }
            return (plain + close, colored + close)
        }
    }

    /// A line of a `"""` literal: backslashes and control characters (an
    /// escape sequence in a program's output, say) escaped, so it can't be
    /// mistaken for anything else or change the terminal.
    static func escapedForBlock(_ line: String) -> String {
        var result = ""
        for scalar in line.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\t": result += "\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                result += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result.replacingOccurrences(of: "\"\"\"", with: "\\\"\"\"")
    }

    private func paint(_ segments: [Segment]) -> (plain: String, styled: String) {
        (segments.map(\.text).joined(), segments.map { $0.text.styled($0.style, styled) }.joined())
    }
}
