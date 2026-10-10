import Foundation
import SwishKit

extension TypeChecker {
    // MARK: Closures

    @_spi(Shell) public func functionType(_ signature: Signature) -> TypeAnnotation {
        .functionType(signature.parameters.map { $0.variadic ? .list($0.type) : $0.type }, signature.returns,
                      throws: signature.isThrowing)
    }

    /// A closure's type. Parameters without a type take the ones the context
    /// expects (`filter` expects `(Element) -> Bool`), or aren't known; its
    /// result is what the context expects, what it says, or what its
    /// `return`s give; it throws if its body can.
    @_spi(Shell) public func closureType(_ closure: inout ClosureLiteral, expecting expected: TypeAnnotation?) throws -> TypeAnnotation {
        var expectedParameters: [TypeAnnotation]?
        var expectedResult: TypeAnnotation?
        if case .functionType(let parameters, let result, _)? = expected, parameters.count == closure.parameters.count {
            expectedParameters = parameters
            expectedResult = result
        }
        var names: [String: Symbol] = [:]
        var parameterTypes: [TypeAnnotation] = []
        for (index, parameter) in closure.parameters.enumerated() {
            let type = parameter.type == .any ? expectedParameters?[index] ?? .unknown : parameter.type
            parameterTypes.append(type)
            names[parameter.name] = .variable(type, mutable: false)
        }
        let declared = closure.returnType ?? (expectedResult == .unknown ? nil : expectedResult)
        let context = ReturnContext(declared: declared == .void ? nil : declared)
        let sitesBefore = throwingSites
        let tryBefore = tryDepth
        returns.append(context)
        errorContexts.append(ErrorContext(handled: true))
        scopes.append(names)
        tryDepth = 0 // A `try` outside doesn't reach in.
        defer {
            returns.removeLast()
            errorContexts.removeLast()
            scopes.removeLast()
            tryDepth = tryBefore
            // Throwing is what calling it does, not making it.
            throwingSites = sitesBefore
        }

        var result: TypeAnnotation
        if var expr = implicitReturn(closure.body) {
            let type = try typeOf(&expr, expecting: declared)
            closure.body.statements[0] = .expression(expr)
            // A closure of one expression where nothing is wanted back just
            // runs it, as in Swift: `queue.async { log(x) }`.
            if let declared, declared != .void, !fits(type, declared) {
                throw TypeError("the closure must return \(declared), not \(type)")
            }
            result = closure.returnType ?? declared ?? type
        } else {
            try checkBlock(&closure.body)
            result = declared ?? commonType(context.seen) ?? (context.seen.isEmpty ? .void : .unknown)
        }
        return .functionType(parameterTypes, result, throws: throwingSites > sitesBefore)
    }
}
