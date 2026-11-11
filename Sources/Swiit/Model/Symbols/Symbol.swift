import Foundation
import SwiftSyntax
import Synchronization

// What the interpreter says a name is: a function, a variable or a type, and what it has.

extension Symbol {
    /// An attribute written on a declaration, as written: `@discardableResult` is a name with no
    /// arguments, `@available(*, deprecated)` is `available` with two. What an attribute means is up to
    /// whatever looks it up by name: the checker for some, a host for the rest.
    public struct Attribute: Sendable, Hashable {
        /// What follows the `@`.
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

/// Something a script can name: a function or method, a variable or property, or a type. Only a
/// function has parameters and effects, only a variable can be settable: what a symbol is, its kind,
/// decides what it has.
public struct Symbol: Sendable, Hashable {
    public var name: String
    /// The line `help` shows, when it has one.
    public var summary: String?
    public var kind: Kind
    /// The attributes it was declared with: `@discardableResult`, `@available(…)`, and the rest.
    public var attributes: [Symbol.Attribute] = []
    /// Whether the core or the host provides it, as opposed to a script's own declaration.
    public var isBuiltin = false
    /// The type's ID, for a type. Nil for any other symbol, and for a type described by `check`
    /// before the source is run, which declares nothing yet.
    public internal(set) var id: ID?

    public init(
        name: String,
        summary: String? = nil,
        kind: Kind,
        attributes: [Symbol.Attribute] = []
    ) {
        self.name = name
        self.summary = summary
        self.kind = kind
        self.attributes = attributes
    }

    /// The function this is, if it is one: a function, a method or an initializer.
    public var function: Function? {
        switch kind {
        case .function(let function), .initializer(let function): function
        case .method(let method): method.function
        default: nil
        }
    }

    /// The variable this is, if it is one: a global or a property.
    public var variable: Variable? {
        switch kind {
        case .variable(let variable): variable
        case .property(let property): property.variable
        default: nil
        }
    }

    /// Whether it is a type: a struct, an enum, a class, an actor or a protocol.
    public var isType: Bool {
        switch kind {
        case .structure, .enumeration, .class, .actor, .protocol: true
        case .function, .variable, .method, .property, .initializer, .enumCase: false
        }
    }

    /// Its type as a value: a function's is a function type (parameter types in order, what it
    /// returns); a variable's is its own; a type's is the type it names.
    public var scriptType: ScriptType {
        switch kind {
        case .function, .method, .initializer:
            .function(
                parameters: function!.parameters.map(\.type),
                returns: function!.returns,
                isThrowing: function!.isThrowing,
                isAsync: function!.isAsync
            )
        case .variable, .property: variable!.type
        case .structure, .enumeration, .class, .actor, .protocol: .named(id ?? .host(name))
        case .enumCase: .any
        }
    }
}

typealias GenericParameter = Symbol.GenericParameter
