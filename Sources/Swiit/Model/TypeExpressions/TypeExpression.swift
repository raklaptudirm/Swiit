import Foundation
import Synchronization

/// A type as a signature writes it, which is what a function offered to scripts, `symbols`, `overload`
/// and `typeExpression(of:)` speak. Swift's type grammar is small and closed, and so is this: a named
/// type with the types it is generic over (`Int`, `Array<Int>`, `Optional<String>`), a function type, a
/// tuple type, a metatype, or a generic parameter. A ``TypeRef`` says which type a name is; an
/// expression says how a type is written with it, so it can have arguments, and a function type has
/// no reference of its own. Whether a named type is a struct, an enum or a class is a fact about its
/// declaration (``Symbol/Nominal``): `Interpreter.globals(named:)` says.
public indirect enum TypeExpression: Sendable, Hashable, CustomStringConvertible {
    case named(TypeRef, [TypeExpression] = [])
    /// A generic parameter of the declaration the type is written in: `Element` in
    /// `func first() -> Element`. It stands where a type would be, with nothing declared under it.
    case parameter(String)
    /// A function type, with the effects Swift writes after its parameters: `(Element) throws -> Bool`.
    case function(FunctionType)
    case tuple([TupleElement])
    /// The type of a type, as `Tools` is where it is written as a value: `Tools.Type`. What it has
    /// are the type's static members, its initializers and the cases of an enum.
    case metatype(TypeExpression)

    /// The shape of a function type: what it takes, what it gives back, and the effects Swift writes
    /// after its parameters. A declaration's `Symbol.Function` has the same shape and adds what only a
    /// declaration has (labels, names, defaults, documentation, generics).
    public struct FunctionType: Sendable, Hashable {
        public var parameters: [Parameter]
        public var returns: TypeExpression
        /// Whether it throws, and what.
        public var throwing: Throwing
        public var isAsync: Bool

        /// A parameter of a function type: its type, and whether the function changes it in place, as
        /// `reduce(into:)`'s closure changes its accumulator (`(inout Result, Element) -> Void`).
        public struct Parameter: Sendable, Hashable {
            public var type: TypeExpression
            public var isInout: Bool

            public init(_ type: TypeExpression, isInout: Bool = false) {
                self.type = type
                self.isInout = isInout
            }
        }

        public init(
            parameters: [Parameter],
            returns: TypeExpression,
            throwing: Throwing = .no,
            isAsync: Bool = false
        ) {
            self.parameters = parameters
            self.returns = returns
            self.throwing = throwing
            self.isAsync = isAsync
        }

        /// Whether it throws errors of its own: `throws` and `throws(Failure)`.
        public var isThrowing: Bool { throwing != .no }

        /// The errors a function type can throw. Only a declaration is `rethrows`; the type of one
        /// throws, as a closure of it does.
        public enum Throwing: Sendable, Hashable {
            case no
            /// `throws`: any error.
            case any
            /// `throws(Failure)`: errors of this type.
            case typed(TypeExpression)
        }
    }

    /// An element of a tuple type, labeled or not.
    public struct TupleElement: Sendable, Hashable {
        public var label: String?
        public var type: TypeExpression
        public init(label: String? = nil, type: TypeExpression) {
            self.label = label
            self.type = type
        }
    }

    public static let any = TypeExpression.named(.any)
    public static let bool = TypeExpression.named(.bool)
    public static let int = TypeExpression.named(.int)
    public static let double = TypeExpression.named(.double)
    public static let string = TypeExpression.named(.string)
    /// The type of nothing: what a function that gives nothing gives.
    public static let void = TypeExpression.tuple([])
    /// A function whose signature is not said.
    public static let callable = TypeExpression.named(.function)

    /// `[Element]`, which is `Array<Element>`.
    public static func list(_ element: TypeExpression) -> TypeExpression {
        .named(.array, [element])
    }
    /// `[Key: Value]`, which is `Dictionary<Key, Value>`.
    public static func dictionary(_ key: TypeExpression, _ value: TypeExpression) -> TypeExpression
    {
        .named(.dictionary, [key, value])
    }
    /// `Wrapped?`, which is `Optional<Wrapped>`.
    public static func optional(_ wrapped: TypeExpression) -> TypeExpression {
        .named(.optional, [wrapped])
    }

    /// A function type written with the effects as flags: `.function(parameters: [.int], returns: .int)`.
    public static func function(
        parameters: [TypeExpression],
        returns: TypeExpression,
        isThrowing: Bool = false,
        isAsync: Bool = false
    ) -> TypeExpression {
        .function(
            FunctionType(
                parameters: parameters.map { FunctionType.Parameter($0) },
                returns: returns,
                throwing: isThrowing ? .any : .no,
                isAsync: isAsync
            )
        )
    }

    /// A named type by its text, which the module's own tables and checker are written in.
    static func named(_ name: String, _ arguments: [TypeExpression] = []) -> TypeExpression {
        .named(.native(name), arguments)
    }

    public var description: String {
        switch self {
        case .named("Array", let arguments) where arguments.count == 1: "[\(arguments[0])]"
        case .named("Dictionary", let arguments) where arguments.count == 2:
            "[\(arguments[0]): \(arguments[1])]"
        case .named("Optional", let arguments) where arguments.count == 1: "\(arguments[0])?"
        case .named(let name, let arguments):
            arguments.isEmpty
                ? name.name : "\(name)<\(arguments.map(\.description).joined(separator: ", "))>"
        case .parameter(let name): name
        case .function(let function):
            "(\(function.parameters.map(\.description).joined(separator: ", ")))"
                + (function.isAsync ? " async" : "") + function.throwingText
                + " -> \(function.returns)"
        case .metatype(let type): "\(type).Type"
        case .tuple(let elements):
            "("
                + elements.map { ($0.label.map { "\($0): " } ?? "") + $0.type.description }
                .joined(separator: ", ")
                + ")"
        }
    }
}

extension TypeExpression.FunctionType.Parameter: CustomStringConvertible {
    public var description: String { isInout ? "inout \(type)" : type.description }
}

extension TypeExpression.FunctionType {
    /// ` throws`, ` throws(Failure)` or nothing, as Swift writes it after the parameters.
    fileprivate var throwingText: String {
        switch throwing {
        case .no: ""
        case .any: " throws"
        case .typed(let failure): " throws(\(failure))"
        }
    }
}
