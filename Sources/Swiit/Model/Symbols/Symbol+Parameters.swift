import Foundation
import SwiftSyntax
import Synchronization

// A function's parameters and generic parameters.

extension Symbol {
    /// What a type must be to be given for a type parameter.
    public enum Constraint: Sendable, Hashable {
        /// It conforms to a protocol: `Comparable`, `Hashable`, or one a script declares.
        case conforms(to: TypeExpression)
        /// It is exactly this type, as `where Element == Int` says.
        case equals(TypeExpression)

        /// The module's own tables are written with the names of the types they mean.
        public static let comparable = Constraint.conforms(to: .named("Comparable"))
        public static let hashable = Constraint.conforms(to: .named("Hashable"))
        public static let equatable = Constraint.conforms(to: .named("Equatable"))

        static func conforms(to name: String) -> Constraint { .conforms(to: .named(name)) }
        static func equals(_ name: String) -> Constraint { .equals(.named(name)) }

        /// What one constraint is among others when they are compared: a protocol by its name,
        /// an exact type by that name after an `=`.
        var refinementKey: String {
            switch self {
            case .conforms(let proto): proto.description
            case .equals(let exact): "=" + exact.description
            }
        }
    }

    /// A type parameter, with what it asks of the type given for it: `Element` in `Array<Element>`,
    /// `T` in `func f<T: Comparable>`.
    public static func genericParameter(_ name: String, constraints: [Constraint] = []) -> Symbol {
        Symbol(name: name, kind: .genericParameter(constraints: constraints))
    }

    /// What a type given for it must be, if this is a generic parameter.
    public var constraints: [Constraint] {
        if case .genericParameter(let constraints) = kind { constraints } else { [] }
    }

    /// A parameter of a function.
    public struct Parameter: Sendable, Hashable {
        /// The argument label; nil when the argument is written without one.
        public var label: String?
        /// The name the function's body uses.
        public var name: String
        public var type: TypeExpression
        /// The function changes it in place, and a call passes the variable with `&`: `inout`.
        public var isInout: Bool
        /// Whether a call must give it, may leave it out, or may give any number.
        public var arity: Arity
        /// The type as the checker has it, which tells a type parameter from a type of the same
        /// name.
        var annotation: TypeAnnotation?
        /// The text of the `- Parameter name:` line in the function's documentation.
        public var documentation: String?
        /// What is given is shown as interpolation shows a value (`print`).
        var showsByType = false

        /// How many arguments a parameter takes.
        public enum Arity: Sendable, Hashable {
            case required
            /// A call may leave it out.
            case defaulted(Default)
            /// A call may give any number, as `FilePath...` does.
            case variadic

            /// What it is when the call leaves it out.
            public enum Default: Sendable, Hashable {
                /// A plain value: `false`, `10`, `"-"`.
                case value(Value)
                /// Only Swift can make it, like `Date()`.
                case computed
            }
        }

        public init(
            label: String? = nil,
            name: String,
            type: TypeExpression = .any,
            isInout: Bool = false,
            arity: Arity = .required,
            documentation: String? = nil
        ) {
            self.label = label
            self.name = name
            self.type = type
            self.isInout = isInout
            self.arity = arity
            self.documentation = documentation
        }
    }
}
