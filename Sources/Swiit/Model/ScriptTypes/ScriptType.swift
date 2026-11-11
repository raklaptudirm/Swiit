import Foundation
import Synchronization

/// How a host names a type: a parameter or result of a function it offers, and what `symbols`,
/// `overload` and `scriptType(of:)` speak. Swift's type grammar is small and closed, and so
/// is this: a name with the types it is generic over (`Int`, `Array<Int>`, `Optional<String>`,
/// `Set<String>`), a function type, a tuple type. Whether a named type is a struct, an enum or a
/// class is a fact about its declaration: `Interpreter.globals(named:)` says.
public indirect enum ScriptType: Sendable, Hashable, CustomStringConvertible {
    case named(Symbol.ID, [ScriptType] = [])
    /// A function type, with the effects Swift writes after its parameters: `(Element) throws -> Bool`.
    case function(
        parameters: [ScriptType],
        returns: ScriptType,
        isThrowing: Bool = false,
        isAsync: Bool = false
    )
    case tuple([Element])
    /// The type of a type, as `Tools` is where it is written as a value: `Tools.Type`. What it has
    /// are the type's static members, its initializers and the cases of an enum.
    case metatype(ScriptType)

    /// An element of a tuple type, labeled or not.
    public struct Element: Sendable, Hashable {
        public var label: String?
        public var type: ScriptType
        public init(label: String? = nil, type: ScriptType) {
            self.label = label
            self.type = type
        }
    }

    public static let any = ScriptType.named(.any)
    public static let bool = ScriptType.named(.bool)
    public static let int = ScriptType.named(.int)
    public static let double = ScriptType.named(.double)
    public static let string = ScriptType.named(.string)
    /// The type of nothing: what a function that gives nothing gives.
    public static let void = ScriptType.tuple([])
    /// A function whose signature is not said.
    public static let callable = ScriptType.named(.function)

    /// A generic parameter of the declaration the type is written in: `Element` in
    /// `func first() -> Element`.
    public static func parameter(_ name: String) -> ScriptType { .named(.parameter(name)) }

    /// `[Element]`, which is `Array<Element>`.
    public static func list(_ element: ScriptType) -> ScriptType { .named(.array, [element]) }
    /// `[Key: Value]`, which is `Dictionary<Key, Value>`.
    public static func dictionary(_ key: ScriptType, _ value: ScriptType) -> ScriptType {
        .named(.dictionary, [key, value])
    }
    /// `Wrapped?`, which is `Optional<Wrapped>`.
    public static func optional(_ wrapped: ScriptType) -> ScriptType {
        .named(.optional, [wrapped])
    }

    /// A named type by its text, which the module's own tables and checker are written in.
    static func named(_ name: String, _ arguments: [ScriptType] = []) -> ScriptType {
        .named(.host(name), arguments)
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
        case .function(let parameters, let returns, let isThrowing, let isAsync):
            "(\(parameters.map(\.description).joined(separator: ", ")))"
                + (isAsync ? " async" : "") + (isThrowing ? " throws" : "") + " -> \(returns)"
        case .metatype(let type): "\(type).Type"
        case .tuple(let elements):
            "("
                + elements.map { ($0.label.map { "\($0): " } ?? "") + $0.type.description }
                .joined(separator: ", ")
                + ")"
        }
    }
}
