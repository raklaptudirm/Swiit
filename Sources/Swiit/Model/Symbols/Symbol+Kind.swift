import Foundation
import SwiftSyntax
import Synchronization

// What a symbol is: a variable, a function, a method, a property or a type, and what each holds.

extension Symbol {
    /// What a symbol is. A type is one of the five Swift declares; what it has is for
    /// `ScriptType.members(named:in:)` to say.
    public enum Kind: Sendable, Hashable {
        /// A function, as a script declares or a host registers one.
        case function(Function)
        /// A global: its type, and whether a script can assign to it.
        case variable(Variable)
        /// A method of a type: a function that also says whether it changes its value and whether
        /// it is the type's own.
        case method(Method)
        /// A property of a type: a variable that also says whether it is the type's own.
        case property(Property)
        /// An initializer of a type: what it takes, and the type it makes.
        case initializer(Function)
        /// A case of an enum: the values it carries (none for most), and its raw value when the
        /// enum has them.
        case enumCase(parameters: [Parameter], rawValue: Value?)
        case structure, enumeration, `class`, actor, `protocol`
    }

    /// A variable: its type, and whether a script can assign to it.
    public struct Variable: Sendable, Hashable {
        public var type: ScriptType
        public var isSettable: Bool

        public init(type: ScriptType, isSettable: Bool = false) {
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

    /// What a function, or reading a property, can throw.
    public enum Throwing: Sendable, Hashable {
        case no
        /// `throws`: any error.
        case any
        /// `rethrows`: only what the closures it is given throw.
        case rethrowing
        /// `throws(Failure)`: errors of this type.
        case typed(ScriptType)
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
        public var returns: ScriptType
        /// Whether it can throw, and what: any error, only what a closure argument throws, or one
        /// type of error.
        public var throwing: Throwing
        public var isAsync: Bool
        /// What it asks of its type parameters, by name: `["Element": ["Comparable"]]` for
        /// `sorted()`. A protocol written `=Int` is a type it must be exactly.
        public var generics: [GenericParameter]

        /// Whether it throws errors of its own, as `throws` and `throws(Failure)` do: not a
        /// `rethrows` function, which throws only what its closures do. Setting it says `throws`
        /// or nothing.
        public var isThrowing: Bool {
            get { throwing != .no && throwing != .rethrowing }
            set { throwing = newValue ? .any : .no }
        }

        public init(
            parameters: [Parameter] = [],
            returns: ScriptType = .void,
            isThrowing: Bool = false,
            isAsync: Bool = false,
            generics: [GenericParameter] = []
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
            returns: ScriptType = .void,
            throwing: Throwing,
            isAsync: Bool = false,
            generics: [GenericParameter] = []
        ) {
            self.generics = generics
            self.parameters = parameters
            self.returns = returns
            self.throwing = throwing
            self.isAsync = isAsync
        }
    }
}
