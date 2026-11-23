import Foundation

// What the checker's descriptions of types are called by identity: a reference for each.

extension TypeChecker {
    /// The reference a type of this name has where the checker is: the one reserved for it if the
    /// program being read declares it, else that of the declared type the name means, else the Swift
    /// type's own.
    func reference(toType name: String) -> TypeRef {
        interpreter.reservedRefs[name] ?? interpreter.typeRef(named: name) ?? .native(name)
    }

    /// What is said of a type apart from its members: its kind, reference, generic parameters and
    /// conformances. Nil for a type the program did not declare.
    func nominal(of profile: TypeProfile) -> Symbol.Nominal? {
        guard let kind = profile.kind else { return nil }
        return Symbol.Nominal(
            name: profile.name,
            kind: kind,
            typeRef: reference(toType: profile.name),
            genericParameters: profile.typeParameters.map {
                Symbol.GenericParameter(name: $0, constraints: [])
            },
            conformances: Dictionary(
                profile.conformances.map { (reference(toType: $0), []) },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }
}
