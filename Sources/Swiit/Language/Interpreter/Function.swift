import Foundation
import SwiitKit

public enum FunctionBody {
    case swiit(Program)
    /// A builtin written in Swift, called with the bound arguments.
    case native((Interpreter, [String: Value]) throws -> Value)
    /// A builtin that transforms its `@input` stream lazily, so `first 5`
    /// can stop pulling after five items.
    case stream((Interpreter, ValueStream, [String: Value]) throws -> ValueStream)
}

/// A Swiit function or closure, or a builtin written in Swift. Both get the
/// same argument binding, help, overloads and streaming.
public final class Function: Callable, @unchecked Sendable {
    public let name: String?
    public let parameters: [Parameter]
    public let returnType: TypeAnnotation?
    public let body: FunctionBody
    public let captured: [Scope]
    public let documentation: Documentation?
    /// A struct's `mutating func` (or `init`), which may change `self`.
    public let isMutating: Bool
    /// `throws`: a call to it needs `try`.
    public let isThrowing: Bool
    /// `rethrows`: a call throws if a closure passed to it does.
    public let isRethrowing: Bool
    /// `async` if declared so.
    public let effect: Effect
    /// Type parameters and their constraints, for a generic builtin.
    public let generics: [String: [String]]
    /// `init?`: leaving it with `return nil` makes nothing.
    let isFailable: Bool
    /// `convenience init`: made through another of the class's initializers.
    let isConvenience: Bool
    /// The class whose body it is in, which `super` in it looks above.
    public weak var owner: ClassType?

    public init(
        name: String?, parameters: [Parameter], returnType: TypeAnnotation?, body: FunctionBody,
        captured: [Scope] = [], documentation: Documentation? = nil, isMutating: Bool = false,
        isThrowing: Bool = false, isRethrowing: Bool = false, effect: Effect = .sync, generics: [String: [String]] = [:],
        isFailable: Bool = false, isConvenience: Bool = false
    ) {
        self.isFailable = isFailable
        self.isConvenience = isConvenience
        self.isRethrowing = isRethrowing
        self.effect = effect
        self.generics = generics
        self.isMutating = isMutating
        self.isThrowing = isThrowing
        self.name = name
        self.parameters = parameters
        self.returnType = returnType
        self.body = body
        self.captured = captured
        self.documentation = documentation
    }

    public var inputParameter: Parameter? {
        parameters.first(where: \.isInput)
    }

    /// Whether a new declaration would replace this one rather than overload it.
    public func hasSameSignature(as other: Function) -> Bool {
        let signature = { (p: Parameter) in [p.label ?? "_", p.type.description, "\(p.variadic)", "\(p.isInput)"] }
        return parameters.map(signature) == other.parameters.map(signature)
    }

    public var description: String {
        guard let name else { return "<closure>" }
        let labels = parameters.map { ($0.label ?? "_") + ":" }.joined()
        return "<func \(name)(\(labels))>"
    }

    public var isBuiltin: Bool {
        if case .swiit = body { false } else { true }
    }

    /// A body that is a single expression returns its value, as in Swift:
    /// a closure's, or a function's that says what it returns. A function
    /// without `->` returns nothing.
    var implicitReturn: Expr? {
        guard name == nil || returnType != nil, case .swiit(let body) = body, body.statements.count == 1,
              case .expression(let expr) = body.statements[0] else { return nil }
        return expr
    }
}
