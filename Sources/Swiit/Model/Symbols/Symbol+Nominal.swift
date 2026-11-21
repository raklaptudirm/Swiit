import Foundation

extension Symbol {
    /// What a type symbol has beyond a name: which of the five kinds of type Swift declares, the
    /// reference that names it, the types it is generic over, and the protocols it conforms to. A
    /// type a script declares, a type a host offers and a type the core bridges are described the same
    /// way. What the type has (methods, properties, initializers, cases, associated types) is read
    /// with ``TypeExpression/members(named:in:)``.
    public struct Nominal: Sendable, Hashable {
        /// The five kinds of nominal type Swift declares.
        public enum Kind: Sendable, Hashable {
            case structure, enumeration, `class`, actor, `protocol`
        }

        public var kind: Kind
        /// The reference that names the type. A type that `check` describes before its source is run
        /// has a reference nothing is declared under yet.
        public var typeRef: TypeRef
        /// A generic type's parameters, `Element` for an array, each with what it must be.
        public var genericParameters: [Symbol]
        /// The protocols it conforms to, each with what its generic parameters must be for it: a
        /// `ClosedRange` is a `Sequence` when its `Bound` is an `Int`.
        public var conformances: [String: [Symbol]]

        public init(
            kind: Kind,
            typeRef: TypeRef,
            genericParameters: [Symbol] = [],
            conformances: [String: [Symbol]] = [:]
        ) {
            self.kind = kind
            self.typeRef = typeRef
            self.genericParameters = genericParameters
            self.conformances = conformances
        }
    }
}
