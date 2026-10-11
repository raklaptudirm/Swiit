import Foundation
import SwishKit

extension TypeChecker {
    // MARK: Closures

    @_spi(Shell) public func functionType(_ signature: Signature) -> TypeAnnotation {
        .functionType(signature.parameters.map { $0.variadic ? .list($0.type) : $0.type }, signature.returns,
                      throws: signature.isThrowing, async: signature.effect)
    }

    /// `async let`'s operation: what it gives, and whether it throws.
    @_spi(Shell) public func childTaskType(_ closure: inout ClosureLiteral) throws -> (TypeAnnotation, Bool) {
        // Its initializer is implicitly `try await`, as in Swift: what it
        // waits for and throws, reading the variable does.
        guard case .functionType(_, let result, let throwing, _) = try closureType(&closure, expecting: nil, implicitTryAwait: true) else {
            return (.unknown, true)
        }
        return (result, throwing)
    }

    /// A closure's type. Parameters without a type take the ones the context
    /// expects (`filter` expects `(Element) -> Bool`), or aren't known; its
    /// result is what the context expects, what it says, or what its
    /// `return`s give; it throws if its body can.
    @_spi(Shell) public func closureType(_ closure: inout ClosureLiteral, expecting expected: TypeAnnotation?,
                                         implicitTryAwait: Bool = false) throws -> TypeAnnotation {
        var expectedParameters: [TypeAnnotation]?
        var expectedResult: TypeAnnotation?
        if case .functionType(let parameters, let result, _, _)? = expected, parameters.count == closure.parameters.count {
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
        tryDepth = implicitTryAwait ? 1 : 0 // A `try` outside doesn't reach in.
        defer {
            returns.removeLast()
            errorContexts.removeLast()
            scopes.removeLast()
            tryDepth = tryBefore
            // Throwing is what calling it does, not making it.
            throwingSites = sitesBefore
        }

        // A closure may `await`, which makes it async, as in Swift; one that
        // waits only through the shell's constructs is implicitly async.
        let (result, effects) = try withEffects(allowsAwait: true) { () throws -> TypeAnnotation in
            if implicitTryAwait { awaitDepth = 1 }
            if var expr = implicitReturn(closure.body) {
                let type = try typeOf(&expr, expecting: declared)
                closure.body.statements[0] = .expression(expr)
                // A closure of one expression where nothing is wanted back just
                // runs it, as in Swift: `queue.async { log(x) }`.
                if let declared, declared != .void, !fits(type, declared) {
                    throw TypeError("the closure must return \(declared), not \(type)")
                }
                return closure.returnType ?? declared ?? type
            }
            try checkBlock(&closure.body)
            return declared ?? commonType(context.seen) ?? (context.seen.isEmpty ? .void : .unknown)
        }
        return .functionType(parameterTypes, result, throws: throwingSites > sitesBefore, async: effects.effect)
    }
}
