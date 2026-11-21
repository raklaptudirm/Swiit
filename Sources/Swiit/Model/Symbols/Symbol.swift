import Foundation
import SwiftSyntax
import Synchronization

// What the interpreter says a name is: a type, a function, a variable or a member of a type, and what each has.

extension Symbol {
    /// The name, summary and attributes every symbol has. A symbol of each kind (`Symbol.Function`,
    /// `Symbol.Nominal`, and the rest) is a struct that holds a `Header` and what only its kind has,
    /// and `Symbol` is the enum of them for a place that takes any.
    public protocol Declaration: Sendable, Hashable {
        var header: Symbol.Header { get set }
    }
}

extension Symbol.Declaration {
    public var name: String {
        get { header.name }
        set { header.name = newValue }
    }

    /// The line `help` shows, when it has one.
    public var summary: String? {
        get { header.summary }
        set { header.summary = newValue }
    }

    /// The attributes it was declared with: `@discardableResult`, `@available(…)`, and the rest.
    public var attributes: [Symbol.Attribute] {
        get { header.attributes }
        set { header.attributes = newValue }
    }

    /// Whether the core or the host provides it, as opposed to a script's own declaration.
    public internal(set) var isBuiltin: Bool {
        get { header.isBuiltin }
        set { header.isBuiltin = newValue }
    }
}

/// Something a script can name: a type, a function, a variable, or a member of a type. The kind of
/// symbol decides what it has: only a function has parameters and effects, only a variable can be
/// settable. Each case holds the symbol of its kind, which has everything its kind has, so an API
/// that always gives a function names `Symbol.Function`.
public enum Symbol: Symbol.Declaration {
    case type(Nominal)
    case function(Function)
    case variable(Variable)
    case method(Method)
    case property(Property)
    case initializer(Initializer)
    case enumCase(EnumCase)
    case associatedType(AssociatedType)
    case genericParameter(GenericParameter)

    /// The parts every kind of symbol has, held once.
    public struct Header: Sendable, Hashable {
        public var name: String
        /// The line `help` shows, when it has one.
        public var summary: String?
        /// The attributes it was declared with.
        public var attributes: [Symbol.Attribute]
        /// Whether the core or the host provides it.
        public internal(set) var isBuiltin: Bool

        public init(name: String, summary: String? = nil, attributes: [Symbol.Attribute] = []) {
            self.name = name
            self.summary = summary
            self.attributes = attributes
            self.isBuiltin = false
        }
    }

    public var header: Header {
        get {
            switch self {
            case .type(let symbol): symbol.header
            case .function(let symbol): symbol.header
            case .variable(let symbol): symbol.header
            case .method(let symbol): symbol.header
            case .property(let symbol): symbol.header
            case .initializer(let symbol): symbol.header
            case .enumCase(let symbol): symbol.header
            case .associatedType(let symbol): symbol.header
            case .genericParameter(let symbol): symbol.header
            }
        }
        set {
            switch self {
            case .type(var symbol): symbol.header = newValue; self = .type(symbol)
            case .function(var symbol): symbol.header = newValue; self = .function(symbol)
            case .variable(var symbol): symbol.header = newValue; self = .variable(symbol)
            case .method(var symbol): symbol.header = newValue; self = .method(symbol)
            case .property(var symbol): symbol.header = newValue; self = .property(symbol)
            case .initializer(var symbol): symbol.header = newValue; self = .initializer(symbol)
            case .enumCase(var symbol): symbol.header = newValue; self = .enumCase(symbol)
            case .associatedType(var symbol):
                symbol.header = newValue; self = .associatedType(symbol)
            case .genericParameter(var symbol):
                symbol.header = newValue; self = .genericParameter(symbol)
            }
        }
    }
}

extension Symbol {
    /// An attribute written on a declaration, as written: `@discardableResult` is a name with no
    /// arguments, `@available(*, deprecated)` is `available` with two. What an attribute means is up to
    /// whatever looks it up by name: the checker for some, a host for the rest.
    public struct Attribute: Sendable, Hashable {
        /// The attribute's name, after the `@`.
        public var name: String
        /// The text between the parentheses, one element per comma-separated argument.
        public var arguments: [String]

        public init(name: String, arguments: [String] = []) {
            self.name = name
            self.arguments = arguments
        }
    }
}

extension Sequence where Element == Symbol.Attribute {
    /// Whether one named `name` is among them.
    public func contains(named name: String) -> Bool {
        contains { $0.name == name }
    }
}
