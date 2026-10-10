import Foundation
import SwishKit

@_spi(Shell) public enum FunctionBody {
    case swish(Program)
    /// A builtin written in Swift, called with the bound arguments.
    case native((Interpreter, [String: Value]) throws -> Value)
    /// A builtin that transforms its `@input` stream lazily, so `first 5`
    /// can stop pulling after five items.
    case stream((Interpreter, ValueStream, [String: Value]) throws -> ValueStream)
}

/// A Swish function or closure, or a builtin written in Swift. Both get the
/// same argument binding, help, overloads and streaming.
@_spi(Shell) public final class Function: Callable, @unchecked Sendable {
    @_spi(Shell) public let name: String?
    @_spi(Shell) public let parameters: [Parameter]
    @_spi(Shell) public let returnType: TypeAnnotation?
    @_spi(Shell) public let body: FunctionBody
    @_spi(Shell) public let captured: [Scope]
    @_spi(Shell) public let documentation: Documentation?
    /// The imported module it came from, for a plugin's function.
    @_spi(Shell) public let plugin: String?
    /// A struct's `mutating func` (or `init`), which may change `self`.
    @_spi(Shell) public let isMutating: Bool
    /// `throws`: a call to it needs `try`.
    @_spi(Shell) public let isThrowing: Bool
    /// `rethrows`: a call throws if a closure passed to it does.
    @_spi(Shell) public let isRethrowing: Bool
    /// Type parameters and their constraints, for a generic builtin.
    @_spi(Shell) public let generics: [String: [String]]

    @_spi(Shell) public init(
        name: String?, parameters: [Parameter], returnType: TypeAnnotation?, body: FunctionBody,
        captured: [Scope] = [], documentation: Documentation? = nil, plugin: String? = nil, isMutating: Bool = false,
        isThrowing: Bool = false, isRethrowing: Bool = false, generics: [String: [String]] = [:]
    ) {
        self.isRethrowing = isRethrowing
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

    @_spi(Shell) public var inputParameter: Parameter? {
        parameters.first(where: \.isInput)
    }

    /// Whether a new declaration would replace this one rather than overload it.
    @_spi(Shell) public func hasSameSignature(as other: Function) -> Bool {
        let signature = { (p: Parameter) in [p.label ?? "_", p.type.description, "\(p.variadic)", "\(p.isInput)"] }
        return parameters.map(signature) == other.parameters.map(signature)
    }

    @_spi(Shell) public var description: String {
        guard let name else { return "<closure>" }
        let labels = parameters.map { ($0.label ?? "_") + ":" }.joined()
        return "<func \(name)(\(labels))>"
    }

    @_spi(Shell) public var isBuiltin: Bool {
        if case .swish = body { false } else { true }
    }

    /// A body that is a single expression returns its value, as in Swift:
    /// a closure's, or a function's that says what it returns. A function
    /// without `->` returns nothing.
    @_spi(Shell) public var implicitReturn: Expr? {
        guard name == nil || returnType != nil, case .swish(let body) = body, body.statements.count == 1,
              case .expression(let expr) = body.statements[0] else { return nil }
        return expr
    }
}
