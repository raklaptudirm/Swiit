import Foundation

/// What is said of a type: its symbol, and what its Swift type says of itself. A type a host
/// offers, a type a program declares and a type the core bridges are described the same way.
public struct TypeDeclaration: Sendable, Hashable {
    /// What a script sees of the type: its name, documentation, attributes and kind.
    public var symbol: Symbol
    /// A generic type's parameters, `Element` for an array, each with what it must be.
    public var genericParameters: [Symbol] = []
    /// The protocols it conforms to, each with what its generic parameters must be for it: a
    /// `ClosedRange` is a `Sequence` when its `Bound` is an `Int`.
    public var conformances: [String: [Symbol]] = [:]
    /// What its associated types are: `Element` is `String` for a sequence of text.
    public var associatedTypes: [String: ScriptType] = [:]

    public init(symbol: Symbol) {
        self.symbol = symbol
    }

    /// A type held by value under its name, as a host's is: a structure.
    public init(name: String) {
        symbol = Symbol(name: name, kind: .type(.structure))
        symbol.typeRef = .native(name)
    }

    public var name: String {
        get { symbol.name }
        set {
            symbol.name = newValue
            symbol.typeRef = .native(newValue)
        }
    }
}
