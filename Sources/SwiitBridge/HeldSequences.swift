import Foundation

// A sequence type a function gives back that Swift makes lazily (`Zip2Sequence`, `LazySequence`,
// `ReversedCollection`) is held as the array it would give, as Swiit holds `zip`'s result. A
// type is listed (`--as-array`, `asArray`) because only its author can say that it ends.

/// A listed sequence type: its generic parameters, and the type of its elements in terms of them.
struct HeldSequence {
    let parameters: [String]
    let element: SType
}

// safe: the generator runs on one thread
nonisolated(unsafe) var heldSequences: [String: HeldSequence] = [:]

/// Reads what each listed type says of its generic parameters and its `Element` from the graph.
func loadHeldSequences(_ names: [String], in graph: Graph) throws {
    for name in names {
        guard
            let symbol = graph.symbols.first(where: {
                $0.pathComponents == [name] && $0.kind.identifier == "swift.struct"
            })
        else { throw Failure("\(graph.module.name) has no struct \(name) to hold as an array") }
        // Where the standard library says its elements: on the type, or on its iterator, which
        // some versions say only there, or which the type's own alias points to.
        let parameters = symbol.swiftGenerics?.parameters?.map(\.name) ?? []
        var target: SType
        if let own = try? elementAlias([name], in: graph) {
            target = own
            if case .member(.member(.named(name, _), "Iterator"), "Element") = own {
                target = try elementAlias([name, "Iterator"], in: graph)
            }
        } else if let viaIterator = try? elementAlias([name, "Iterator"], in: graph) {
            target = viaIterator
        } else if parameters.contains("Element") {
            // `StrideTo<Element>`: its elements are what it is generic over.
            target = .named("Element", [])
        } else {
            throw Failure("\(name) has no Element to hold as an array")
        }
        heldSequences[name] = HeldSequence(
            parameters: parameters,
            element: target
        )
    }
}

private func elementAlias(_ path: [String], in graph: Graph) throws -> SType {
    guard
        let alias = graph.symbols.first(where: {
            $0.pathComponents == path + ["Element"] && $0.kind.identifier == "swift.typealias"
        }),
        case let text = (alias.declarationFragments ?? []).map(\.spelling).joined(),
        let equals = text.range(of: "=")
    else { throw Failure("\(path.joined(separator: ".")) has no Element to hold as an array") }
    var reader = Reader(String(text[equals.upperBound...]))
    return try reader.type()
}

/// A listed sequence type with its arguments as a member of `context`'s owner sees them: the array
/// of its elements. Nil if `name` is not listed, or its arguments cannot be bridged.
func resolveHeld(_ name: String, _ arguments: [SType], _ context: Context) -> SType?? {
    guard let held = heldSequences[name], arguments.count == held.parameters.count else {
        return nil
    }
    let resolved = arguments.compactMap { resolve($0, context) }
    guard resolved.count == arguments.count else { return .some(nil) }
    let element = substitute(
        held.element,
        Dictionary(uniqueKeysWithValues: zip(held.parameters, resolved))
    )
    return .some(resolve(element, context).map(SType.held))
}

/// `type` with each generic parameter in `bindings` replaced, and `X.Element` of a type that is a
/// sequence replaced by its element.
func substitute(_ type: SType, _ bindings: [String: SType]) -> SType {
    switch type {
    case .named(let name, []): return bindings[name] ?? type
    case .named(let name, let arguments):
        return .named(name, arguments.map { substitute($0, bindings) })
    case .member(let base, "Element"):
        let base = substitute(base, bindings)
        return elementOf(base) ?? .member(base, "Element")
    case .member(let base, let name): return .member(substitute(base, bindings), name)
    case .array(let element): return .array(substitute(element, bindings))
    case .optional(let wrapped): return .optional(substitute(wrapped, bindings))
    case .dictionary(let key, let value):
        return .dictionary(substitute(key, bindings), substitute(value, bindings))
    case .tuple(let elements):
        return .tuple(
            elements.map { .init(label: $0.label, type: substitute($0.type, bindings)) }
        )
    case .function(let parameters, let result, let throwing, let isAsync):
        return .function(
            parameters.map { substitute($0, bindings) },
            substitute(result, bindings),
            throwing: throwing,
            async: isAsync
        )
    case .someSequence(let element): return .someSequence(substitute(element, bindings))
    case .inOut(let inner): return .inOut(substitute(inner, bindings))
    case .held(let element): return .held(substitute(element, bindings))
    }
}

/// The type of the elements of a resolved sequence type, if the generator knows it.
func elementOf(_ type: SType) -> SType? {
    switch type {
    case .array(let element), .someSequence(let element), .held(let element): return element
    case .named(let name, let arguments):
        if ["Set", "ArraySlice", "Range", "ClosedRange"].contains(name), arguments.count == 1 {
            return arguments[0]
        }
        return types[name]?.associated["Element"]
    default: return nil
    }
}

/// Whether a lazy sequence type that is held as an array is somewhere in `type`.
func containsHeld(_ type: SType) -> Bool {
    switch type {
    case .held: return true
    case .array(let element), .optional(let element), .someSequence(let element),
        .inOut(let element):
        return containsHeld(element)
    case .dictionary(let key, let value): return containsHeld(key) || containsHeld(value)
    case .tuple(let elements): return elements.contains { containsHeld($0.type) }
    case .named(_, let arguments): return arguments.contains(where: containsHeld)
    case .member(let base, _): return containsHeld(base)
    case .function(let parameters, let result, _, _):
        return parameters.contains(where: containsHeld) || containsHeld(result)
    }
}
