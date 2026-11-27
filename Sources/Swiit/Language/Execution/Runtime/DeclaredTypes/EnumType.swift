import Foundation

// What the interpreter keeps of an enum beyond its cases.

// safe: its state is touched only holding the interpreter lock
/// An enum a program declares, beside its `Enumeration`: what the type adds to its cases (computed
/// properties, methods, initializers and statics), and what is said of it. The `Enumeration` is the
/// descriptor of the cases that every value carries and lives in the model layer, which cannot name
/// these members, so the interpreter holds the two together.
final class EnumType: @unchecked Sendable {
    let enumeration: Value.EnumCase.Enumeration
    /// How its values are stored: as one of the cases.
    let representation = ImplementedType.Representation.enumeration
    let members = TypeMembers()
    /// What is said of the type, apart from its conformances, which `Interpreter.typeSymbol` adds
    /// because extensions give them too.
    let symbol: Symbol.Nominal

    init(_ enumeration: Value.EnumCase.Enumeration) {
        self.enumeration = enumeration
        symbol = Symbol.Nominal(
            name: enumeration.name,
            kind: .enumeration,
            typeRef: enumeration.typeRef
        )
    }
}
