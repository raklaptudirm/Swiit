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
    /// The kind, reference, generic parameters and conformances of this symbol, if it is a type.
    public var nominal: Nominal? {
        get { if case .type(let nominal) = kind { nominal } else { nil } }
        set {
            guard case .type = kind, let newValue else { return }
            kind = .type(newValue)
        }
    }

    /// The type's reference, for a type: nil for any other symbol.
    public var typeRef: TypeRef? { nominal?.typeRef }

    /// Which kind of type this is, if it is one.
    public var typeKind: Nominal.Kind? { nominal?.kind }

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
        case .function(let function), .member(.initializer(let function)): function
        case .member(.method(let method)): method.function
        default: nil
        }
    }

    /// The variable this is, if it is one: a global or a property.
    public var variable: Variable? {
        switch kind {
        case .variable(let variable): variable
        case .member(.property(let property)): property.variable
        default: nil
        }
    }

    /// Whether it is a type: a struct, an enum, a class, an actor or a protocol.
    public var isType: Bool {
        if case .type = kind { true } else { false }
    }

    /// This symbol's type as a value. A function's is a function type (its parameter types in order, and
    /// what it returns), a variable's is its own type, and a type's is the type it names. A type parameter's,
    /// or an associated type a protocol asks for, is the parameter itself, and an associated type a type
    /// binds is what it is bound to.
    public var typeExpression: TypeExpression {
        switch kind {
        case .function, .member(.method), .member(.initializer): .function(function!.functionType)
        case .variable, .member(.property): variable!.type
        case .type(let nominal): .named(nominal.typeRef)
        case .member(.enumCase): .any
        case .member(.associatedType(.binding(let type))): type
        case .member(.associatedType(.requirement)), .genericParameter: .parameter(name)
        }
    }
}
