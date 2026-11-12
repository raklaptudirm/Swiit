import Foundation

// A generic member that Swiit cannot hold as a generic, because its parameter must be a type the
// glue can name (`stride<T: Strideable>`, `subscript<R: RangeExpression>`), is bridged once for each
// type listed for the protocol: `--specialize Strideable=Int,Double`. A type that is generic
// itself (`Range`) takes its argument from the member's own constraint (`R.Bound == Self.Index`).

// safe: the generator runs on one thread
nonisolated(unsafe) var specializations: [String: [String]] = [:]

/// Reads `Protocol=Type,Type` from `--specialize`.
func addSpecialization(_ text: String) {
    let pair = text.split(separator: "=", maxSplits: 1).map(String.init)
    guard pair.count == 2 else { return }
    specializations[pair[0], default: []] += pair[1].split(separator: ",").map(String.init)
}

/// The ways a generic parameter of `declaration` is bound, one for each type listed for a protocol
/// it conforms to; none if it has no such parameter.
func specializationBindings(
    of declaration: Declaration,
    _ symbol: Symbol,
    given conditions: [Constraint] = []
) -> [[String: SType]] {
    let constraints =
        conditions + (symbol.swiftExtension?.constraints ?? [])
        + (symbol.swiftGenerics?.constraints ?? []) + declaration.constraints
    for (parameter, written) in declaration.generics.sorted(by: { $0.key < $1.key }) {
        let protocols = Set(
            written
                + constraints.filter { $0.kind == "conformance" && $0.lhs == parameter }.map(\.rhs)
        )
        guard let listed = protocols.compactMap({ specializations[$0] }).first else { continue }
        return listed.compactMap { name -> [String: SType]? in
            // A type with a generic argument of its own, from `Parameter.Bound == X`.
            if leaves[name] == nil, let bound = boundType(of: parameter, in: constraints) {
                return [parameter: .named(name, [bound])]
            }
            return leaves[name] == nil ? nil : [parameter: .named(name, [])]
        }
    }
    return []
}

/// `X`, from a constraint `X == Parameter.Bound` (either way round).
private func boundType(of parameter: String, in constraints: [Constraint]) -> SType? {
    for constraint in constraints where constraint.kind == "sameType" {
        let pair =
            constraint.rhs == "\(parameter).Bound"
            ? constraint.lhs : constraint.lhs == "\(parameter).Bound" ? constraint.rhs : nil
        if let pair, var reader = Optional(Reader(pair)), let type = try? reader.type() {
            return type
        }
    }
    return nil
}

extension Declaration {
    /// It with each generic parameter of `bindings` the type it is bound to.
    mutating func specialize(_ bindings: [String: SType]) {
        for name in bindings.keys { generics.removeValue(forKey: name) }
        parameters = parameters.map {
            Parameter(
                label: $0.label,
                name: $0.name,
                type: substitute($0.type, bindings),
                defaultText: $0.defaultText,
                isVariadic: $0.isVariadic
            )
        }
        returns = returns.map { substitute($0, bindings) }
        constraints = constraints.filter { !$0.mentions(Set(bindings.keys)) }
    }
}

extension Constraint {
    /// Whether it says something of one of the generic parameters `names`.
    func mentions(_ names: Set<String>) -> Bool {
        func head(_ text: String) -> String { String(text.prefix { $0 != "." }) }
        return names.contains(head(lhs)) || names.contains(head(rhs))
    }
}
