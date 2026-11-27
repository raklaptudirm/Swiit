import Foundation

// Patterns as Swift source: of a `case`, a `catch` and a `for`.

extension SwiftPrinter {
    func labelText(_ label: String?) -> String { label.map { "\($0): " } ?? "" }

    /// A `for`'s pattern: names without `let`.
    func loopPattern(_ pattern: Pattern) -> String {
        switch pattern {
        case .binding(let name, _): name
        case .tuple(let patterns): "(" + patterns.map(loopPattern).joined(separator: ", ") + ")"
        default: self.pattern(pattern)
        }
    }

    func pattern(_ pattern: Pattern) -> String {
        switch pattern {
        case .wildcard: "_"
        case .binding(let name, let mutable): "\(mutable ? "var" : "let") \(name)"
        case .enumCase(let type, let name, let arguments):
            "\(type ?? "").\(name)"
                + (arguments.map { arguments in
                    "("
                        + arguments.map { argument in
                            (argument.label.map { "\($0): " } ?? "")
                                + self.pattern(argument.pattern)
                        }
                        .joined(separator: ", ") + ")"
                } ?? "")
        case .expression(let expr): expression(expr)
        case .cast(let inner, let type): "\(self.pattern(inner)) as \(type)"
        case .isType(let type): "is \(type)"
        case .tuple(let patterns):
            "(" + patterns.map { self.pattern($0) }.joined(separator: ", ") + ")"
        case .some(let inner): self.pattern(inner) + "?"
        case .partialRange(let lower, let upper, let closed):
            (lower.map { expression($0) } ?? "") + (closed ? "..." : "..<")
                + (upper.map { expression($0) } ?? "")
        }
    }
}
