import Foundation
import SwiftSyntax
import Synchronization

// What a symbol is: a variable, a function, a method, a property or a type, and what each holds.

extension Symbol {
    /// What a symbol is: a type, a global function or variable, or a member of a type. A type's own members
    /// are read with `TypeExpression.members(named:in:)`.
    public enum Kind: Sendable, Hashable {
        /// A type, with what only a type has.
        case type(Nominal)
        /// A function, as a script declares or a host registers one.
        case function(Function)
        /// A global: its type, and whether a script can assign to it.
        case variable(Variable)
        /// Something a type has.
        case member(Member)
        /// A type parameter, with what it asks of the type given for it.
        case genericParameter(constraints: [Constraint])

        /// Whether it is an associated type.
        var isAssociatedType: Bool {
            if case .member(.associatedType) = self { true } else { false }
        }

        /// Written as a symbol is declared: a method, a property, an initializer, an enum case or an
        /// associated type of a type.
        public static func method(_ method: Method) -> Kind { .member(.method(method)) }
        public static func property(_ property: Property) -> Kind { .member(.property(property)) }
        public static func initializer(_ function: Function) -> Kind {
            .member(.initializer(function))
        }
        public static func enumCase(parameters: [Parameter], rawValue: Value?) -> Kind {
            .member(.enumCase(parameters: parameters, rawValue: rawValue))
        }
        public static func associatedType(_ associatedType: AssociatedType) -> Kind {
            .member(.associatedType(associatedType))
        }
    }

    /// A member of a type: a method, a property, an initializer, a case or an associated type.
    public enum Member: Sendable, Hashable {
        /// A function that also says whether it changes its value and whether it is the type's own.
        case method(Method)
        /// A variable that also says whether it is the type's own.
        case property(Property)
        /// What it takes, and the type it makes.
        case initializer(Function)
        /// A case of an enum: the values it carries (none for most), and its raw value when the
        /// enum has them.
        case enumCase(parameters: [Parameter], rawValue: Value?)
        /// A type that goes with the type, as `Element` goes with a sequence.
        case associatedType(AssociatedType)
    }

    /// An associated type, which a protocol asks of the types that conform to it and each of them
    /// binds: a sequence's `Element` is `String` for a sequence of text.
    public enum AssociatedType: Sendable, Hashable {
        /// In a protocol: what the type that binds it must conform to.
        case requirement(constraints: [Constraint])
        /// In a type that conforms: the type it is bound to.
        case binding(TypeExpression)
    }

    /// A variable: its type, and whether a script can assign to it.
    public struct Variable: Sendable, Hashable {
        public var type: TypeExpression
        public var isSettable: Bool

        public init(type: TypeExpression, isSettable: Bool = false) {
            self.type = type
            self.isSettable = isSettable
        }
    }

    /// A function that belongs to a type.
    public struct Method: Sendable, Hashable {
        public var function: Function
        /// It changes its value.
        public var isMutating: Bool
        /// It belongs to the type itself, as a `static` member does, and not to a value of it.
        public var isStatic: Bool

        public init(function: Function, isMutating: Bool = false, isStatic: Bool = false) {
            self.function = function
            self.isMutating = isMutating
            self.isStatic = isStatic
        }
    }

    /// What a function or a property read can throw: what a function type can, or `rethrows`, which only a
    /// declaration says (it throws only what the closures it is given throw).
    public enum Throwing: Sendable, Hashable {
        /// `rethrows`: only what the closures it is given throw.
        case rethrowing
        /// What its type throws: nothing, any error, or errors of one type.
        case throwing(TypeExpression.FunctionType.Throwing)

        public static let no = Throwing.throwing(.no)
        /// `throws`: any error.
        public static let any = Throwing.throwing(.any)
        /// `throws(Failure)`: errors of this type.
        public static func typed(_ failure: TypeExpression) -> Throwing {
            .throwing(.typed(failure))
        }

        /// What the type of a function that throws this way throws: a `rethrows` function's type
        /// throws, as a closure of it does.
        var functionTypeThrowing: TypeExpression.FunctionType.Throwing {
            switch self {
            case .rethrowing: .any
            case .throwing(let throwing): throwing
            }
        }
    }

    /// A variable that belongs to a type.
    public struct Property: Sendable, Hashable {
        public var variable: Variable
        /// It belongs to the type itself, as a `static` member does, and not to a value of it.
        public var isStatic: Bool
        /// Reading it needs `await`: `Task.value`.
        public var isAsync: Bool
        /// What reading it can throw.
        public var throwing: Throwing

        public init(
            variable: Variable,
            isStatic: Bool = false,
            isAsync: Bool = false,
            throwing: Throwing = .no
        ) {
            self.variable = variable
            self.isStatic = isStatic
            self.isAsync = isAsync
            self.throwing = throwing
        }
    }

    public struct Function: Sendable, Hashable {
        public var parameters: [Parameter]
        /// What it gives back; `.void` when nothing.
        public var returns: TypeExpression
        /// Whether it can throw, and what: any error, only what a closure argument throws, or one
        /// type of error.
        public var throwing: Throwing
        public var isAsync: Bool
        /// The function's type parameters, each a symbol of kind `.genericParameter` with what it must conform
        /// to: `Element: Comparable` for `sorted()`.
        public var generics: [Symbol]

        /// The type of this function: its shape without labels, names, defaults and documentation. The type of
        /// a `rethrows` function throws, as a closure of it does.
        public var functionType: TypeExpression.FunctionType {
            TypeExpression.FunctionType(
                parameters: parameters.map {
                    TypeExpression.FunctionType.Parameter($0.type, isInout: $0.isInout)
                },
                returns: returns,
                throwing: throwing.functionTypeThrowing,
                isAsync: isAsync
            )
        }

        /// Whether it throws errors of its own, as `throws` and `throws(Failure)` do: not a
        /// `rethrows` function, which throws only what its closures do. Setting it says `throws`
        /// or nothing.
        public var isThrowing: Bool {
            get { throwing != .no && throwing != .rethrowing }
            set { throwing = newValue ? .any : .no }
        }

        public init(
            parameters: [Parameter] = [],
            returns: TypeExpression = .void,
            isThrowing: Bool = false,
            isAsync: Bool = false,
            generics: [Symbol] = []
        ) {
            self.init(
                parameters: parameters,
                returns: returns,
                throwing: isThrowing ? .any : .no,
                isAsync: isAsync,
                generics: generics
            )
        }

        public init(
            parameters: [Parameter] = [],
            returns: TypeExpression = .void,
            throwing: Throwing,
            isAsync: Bool = false,
            generics: [Symbol] = []
        ) {
            self.generics = generics
            self.parameters = parameters
            self.returns = returns
            self.throwing = throwing
            self.isAsync = isAsync
        }
    }
}
