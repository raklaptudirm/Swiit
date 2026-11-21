import Foundation

// The symbols that are called: a function, a method and an initializer, and what they share.

/// A symbol that is called, which has a signature: a function, a method or an initializer.
public protocol CallableSymbol: SymbolProtocol {
    var signature: Symbol.Signature { get }
}

extension CallableSymbol {
    /// The type of this symbol as a value: a function type.
    public var typeExpression: TypeExpression { .function(signature.functionType) }
}

extension Symbol {
    /// The shape a function, a method and an initializer share: what they take, give and can do.
    public struct Signature: Sendable, Hashable {
        public var parameters: [Parameter]
        /// The type it gives back; `.void` when nothing.
        public var returns: TypeExpression
        /// Whether it can throw, and what: any error, only what a closure argument throws, or one
        /// type of error.
        public var throwing: Throwing
        public var isAsync: Bool
        /// The type parameters it is generic over, each with what it must conform to:
        /// `Element: Comparable` for `sorted()`.
        public var generics: [GenericParameter]

        /// The type of what has this signature: its shape without labels, names, defaults and
        /// documentation. The type of a `rethrows` function throws, as a closure of it does.
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
        /// `rethrows` function, which throws only what its closures do.
        public var isThrowing: Bool { throwing != .no && throwing != .rethrowing }

        public init(
            parameters: [Parameter] = [],
            returns: TypeExpression = .void,
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
            returns: TypeExpression = .void,
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

    /// The errors a function, or reading a property, can throw: what a function type can, or
    /// `rethrows`, which only a declaration says (it throws only what the closures it is given
    /// throw).
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

    /// A global function, as a script declares or a host registers one.
    public struct Function: CallableSymbol {
        public var header: Header
        public var signature: Signature

        public init(
            name: String,
            summary: String? = nil,
            attributes: [Attribute] = [],
            signature: Signature
        ) {
            header = Header(name: name, summary: summary, attributes: attributes)
            self.signature = signature
        }
    }

    /// A function that belongs to a type.
    public struct Method: CallableSymbol {
        public var header: Header
        public var signature: Signature
        /// It changes its value.
        public var isMutating: Bool
        /// It belongs to the type itself, as a `static` member does, and not to a value of it.
        public var isStatic: Bool

        public init(
            name: String,
            summary: String? = nil,
            attributes: [Attribute] = [],
            signature: Signature,
            isMutating: Bool = false,
            isStatic: Bool = false
        ) {
            header = Header(name: name, summary: summary, attributes: attributes)
            self.signature = signature
            self.isMutating = isMutating
            self.isStatic = isStatic
        }
    }

    /// How a script makes a value of a type: what it takes, and the type it makes.
    public struct Initializer: CallableSymbol {
        public var header: Header
        public var signature: Signature

        public init(
            summary: String? = nil,
            attributes: [Attribute] = [],
            signature: Signature
        ) {
            header = Header(name: "init", summary: summary, attributes: attributes)
            self.signature = signature
        }
    }
}
