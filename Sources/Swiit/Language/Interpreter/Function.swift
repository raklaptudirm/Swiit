import Foundation
import SwiitKit

@_spi(Host) public enum FunctionBody {
    case swiit(Program)
    /// A builtin written in Swift, called with the bound arguments.
    case native((Interpreter, [String: Value]) throws -> Value)
    /// A builtin that transforms its `@input` stream lazily, so `first 5`
    /// can stop pulling after five items.
    case stream((Interpreter, ValueStream, [String: Value]) throws -> ValueStream)
}

/// A Swiit function or closure, or a builtin written in Swift. Both get the
/// same argument binding, help, overloads and streaming.
@_spi(Host) public final class Function: Callable, @unchecked Sendable {
    @_spi(Host) public let name: String?
    @_spi(Host) public let parameters: [Parameter]
    @_spi(Host) public let returnType: TypeAnnotation?
    @_spi(Host) public let body: FunctionBody
    @_spi(Host) public let captured: [Scope]
    @_spi(Host) public let documentation: Documentation?
    /// The imported module it came from, for a plugin's function.
    @_spi(Host) public let plugin: String?
    /// A struct's `mutating func` (or `init`), which may change `self`.
    @_spi(Host) public let isMutating: Bool
    /// `throws`: a call to it needs `try`.
    @_spi(Host) public let isThrowing: Bool
    /// `rethrows`: a call throws if a closure passed to it does.
    @_spi(Host) public let isRethrowing: Bool
    /// `async` if declared so.
    @_spi(Host) public let effect: Effect
    /// Type parameters and their constraints, for a generic builtin.
    @_spi(Host) public let generics: [String: [String]]

    @_spi(Host) public init(
        name: String?, parameters: [Parameter], returnType: TypeAnnotation?, body: FunctionBody,
        captured: [Scope] = [], documentation: Documentation? = nil, plugin: String? = nil, isMutating: Bool = false,
        isThrowing: Bool = false, isRethrowing: Bool = false, effect: Effect = .sync, generics: [String: [String]] = [:]
    ) {
        self.isRethrowing = isRethrowing
        self.effect = effect
        self.generics = generics
        self.plugin = plugin
        self.isMutating = isMutating
        self.isThrowing = isThrowing
        self.name = name
        self.parameters = parameters
        self.returnType = returnType
        self.body = body
        self.captured = captured
        self.documentation = documentation
    }

    @_spi(Host) public var inputParameter: Parameter? {
        parameters.first(where: \.isInput)
    }

    /// Whether a new declaration would replace this one rather than overload it.
    @_spi(Host) public func hasSameSignature(as other: Function) -> Bool {
        let signature = { (p: Parameter) in [p.label ?? "_", p.type.description, "\(p.variadic)", "\(p.isInput)"] }
        return parameters.map(signature) == other.parameters.map(signature)
    }

    @_spi(Host) public var description: String {
        guard let name else { return "<closure>" }
        let labels = parameters.map { ($0.label ?? "_") + ":" }.joined()
        return "<func \(name)(\(labels))>"
    }

    @_spi(Host) public var isBuiltin: Bool {
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
