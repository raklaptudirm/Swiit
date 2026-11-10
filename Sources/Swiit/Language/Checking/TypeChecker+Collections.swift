import Foundation
import SwiftSyntax

// The types of lists, dictionaries and tuples, and the element type they share.

extension TypeChecker {
    /// Lists, records and tuples.
    func typeOfCollection(
        _ expr: inout Expr,
        expecting expected: TypeAnnotation?
    ) throws -> TypeAnnotation {
        switch expr {
        case .list(var items):
            // `let s: Set<Int> = [1, 2]`: a Swift collection written as a literal is made from its
            // items.
            if var wanted = expected {
                if case .optional(let wrapped) = wanted { wanted = wrapped }
                var typeName: String?
                switch wanted {
                case .named(let name): typeName = name
                case .generic(let name, _): typeName = name
                default: break
                }
                if let typeName, typeName != "Array",
                    Bridge.types[typeName]?.conformances["ExpressibleByArrayLiteral"] != nil
                        || typeName == "Set"
                {
                    expr = .call(.variable(typeName), [Argument(value: .list(items))])
                    let made = try typeOf(&expr, expecting: nil)
                    if case .named = wanted { return made }
                    return wanted
                }
            }
            let type = try listType(&items, expected: expected)
            expr = .list(items)
            return type
        case .record(var entries):
            let type = try dictionaryType(&entries, expected: expected)
            expr = .record(entries)
            return type
        case .tuple(var elements):
            if elements.isEmpty { return .void }
            var wanted: [TypeAnnotation.TupleElement]?
            if case .tuple(let elementTypes)? = expected, elementTypes.count == elements.count {
                wanted = elementTypes
                // `(hi: 2, lo: 1)` where `(lo:, hi:)` is wanted: Swift reorders by the labels.
                let written = elements.map(\.label), labels = elementTypes.map(\.label)
                if !written.contains(nil), !labels.contains(nil), written != labels,
                    Set(written.compactMap { $0 }) == Set(labels.compactMap { $0 })
                {
                    elements = labels.compactMap { label in elements.first { $0.label == label } }
                }
            }
            var types: [TypeAnnotation.TupleElement] = []
            for index in elements.indices {
                types.append(
                    .init(
                        label: elements[index].label,
                        type: try typeOf(
                            &elements[index].value,
                            expecting: wanted?[index].type
                                ?? (expected == .any || expected == .unknown ? .unknown : nil)
                        )
                    )
                )
            }
            expr = .tuple(elements)
            return .tuple(types)
        default:
            preconditionFailure("typeOfExpression sent this to the wrong group")
        }
    }

    func listType(_ items: inout [Expr], expected: TypeAnnotation?) throws -> TypeAnnotation {
        if case .list(let element)? = expected {
            for index in items.indices { try expect(&items[index], element, "a list element") }
            return .list(element)
        }
        if expected == .any {
            // Each by its own type, a `.case` taking its from the others, as in
            // `[Level.high, .low]`.
            _ = try elementTypes(&items)
            return .any
        }
        if expected == .unknown {
            // Wherever it goes takes anything: its own type if it has one.
            return .list(commonType(try elementTypes(&items)) ?? .unknown)
        }
        guard !items.isEmpty else {
            throw TypeError("an empty list needs a type: let xs: [Int] = []")
        }
        // `[1, 2.5]` is a [Double], as in Swift.
        let natural = try elementTypes(&items)
        let wantsDouble = natural.contains(.double)
        var types: [TypeAnnotation] = []
        for index in items.indices {
            types.append(
                wantsDouble ? try typeOf(&items[index], expecting: .double) : natural[index]
            )
        }
        guard let element = commonType(types) else {
            throw TypeError(
                "a list's elements must have one type, not \(Set(types.map(\.description)).sorted().joined(separator: " and ")); write its type, like [Any]"
            )
        }
        return .list(element)
    }

    /// The elements' own types; a `.case` or `nil` takes its type from the
    /// others, as in `[Level.high, .low]`.
    func elementTypes(_ items: inout [Expr]) throws -> [TypeAnnotation] {
        var types = [TypeAnnotation?](repeating: nil, count: items.count)
        for index in items.indices
        where TypeChecker.hasNaturalType(items[index]) || !TypeChecker.isContextual(items[index]) {
            if case .literal(.nothing) = items[index] { continue }
            types[index] = try typeOf(&items[index])
        }
        // In order, each taking its type from those typed before it, so
        // `[c ? K.a : .b, .b]` works.
        for index in items.indices where types[index] == nil {
            let known = commonType(types.compactMap { $0 })
            types[index] = try typeOf(&items[index], expecting: known.map { .optional($0) } ?? nil)
        }
        return types.map { $0! }
    }

    func dictionaryType(
        _ entries: inout [RecordEntry],
        expected: TypeAnnotation?
    ) throws -> TypeAnnotation {
        if case .dictionary(let key, let value)? = expected {
            for index in entries.indices {
                try expect(&entries[index].key, key, "a key")
                try expect(&entries[index].value, value, "a value")
            }
            return .dictionary(key, value)
        }
        guard !entries.isEmpty else {
            throw TypeError("an empty dictionary needs a type: let d: [String: Int] = [:]")
        }
        var keys: [TypeAnnotation] = []
        var values: [TypeAnnotation] = []
        for index in entries.indices {
            keys.append(try typeOf(&entries[index].key))
            values.append(try typeOf(&entries[index].value))
        }
        guard let key = commonType(keys) else {
            throw TypeError("a dictionary's keys must have one type")
        }
        guard let value = commonType(values) else {
            throw TypeError(
                "a dictionary's values must have one type, not \(Set(values.map(\.description)).sorted().joined(separator: " and ")); for a record, write a tuple, like (name: \"x\", size: 2.mb)"
            )
        }
        return .dictionary(key, value)
    }

    /// The one type all of `types` fit, if there is one.
    func commonType(_ types: [TypeAnnotation]) -> TypeAnnotation? {
        guard var common = types.first else { return nil }
        for type in types.dropFirst() {
            if fits(type, common) { continue }
            if fits(common, type) { common = type; continue }
            if common == .unknown || type == .unknown { common = .unknown; continue }
            return nil
        }
        return common
    }
}
