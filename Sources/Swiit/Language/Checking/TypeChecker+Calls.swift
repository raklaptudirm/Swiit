import Foundation
import SwishKit

extension TypeChecker {
    // MARK: Calls

    @_spi(Shell) public func callType(_ callee: inout Expr, _ arguments: inout [Argument], expected: TypeAnnotation?) throws -> TypeAnnotation {
        // `Point(x: 1)`, `Level(rawValue: 2)`, `f(x)`.
        if case .variable(let name) = callee, let symbol = lookup(name) {
            switch symbol {
            case .structType(let info):
                let candidates = info.initializers.isEmpty ? [info.memberwise] : info.initializers
                let chosen = try resolve(candidates, &arguments, name: name)
                if let chosen, !info.initializers.isEmpty { callee = .chosen(callee, overload: chosen.index) }
                if let chosen, chosen.isThrowing { try throwingSite("\(name).init") }
                return .named(name)
            case .enumType(let info):
                guard arguments.count == 1, arguments[0].label == "rawValue" else {
                    throw TypeError("\(name) is made from a raw value: \(name)(rawValue: …)")
                }
                guard let rawType = info.rawType else { throw TypeError("\(name) has no raw values") }
                try expect(&arguments[0].value, rawType, "the raw value")
                return .optional(.named(name))
            case .functions(let overloads):
                return try call(overloads, callee: &callee, &arguments, name: name)
            case .swiftType(let typeName):
                // `String(sub)`: an initializer.
                let (type, bridgedExpr) = try bridgedCall(typeName, kind: .initializer, isStatic: true, receiver: nil, bindings: [:], name: "init", &arguments)
                callee = bridgedExpr
                return type
            default:
                break
            }
        }
        if case .member(.variable(let typeName), let name) = callee, case .swiftType? = lookup(typeName) {
            let (type, bridgedExpr) = try bridgedCall(typeName, kind: .method, isStatic: true, receiver: nil, bindings: [:], name: name, &arguments)
            callee = bridgedExpr
            return type
        }
        // `Point.make(1)`: a static method.
        if case .member(.variable(let typeName), let name) = callee, case .structType(let info)? = lookup(typeName),
           let methods = info.staticMethods[name] {
            guard let chosen = try resolve(methods, &arguments, name: name) else { return commonReturn(methods) }
            if methods.count > 1 { callee = .chosen(callee, overload: chosen.index) }
            if chosen.isThrowing { try throwingSite("'\(name)'") }
            return chosen.returns
        }
        // `x?.f()`: the method's result, or nil.
        if case .optionalMember(var baseExpr, let name) = callee {
            let wrapped = try optionalBase(&baseExpr)
            var member = Expr.member(.annotated(.literal(.nothing), .optional(wrapped)), name)
            let result = try methodCallType(wrapped, baseExpr: baseExpr, name, &member, &arguments)
            // A bridged method on nil is nil (runBridged checks).
            if case .bridged = member { callee = member } else { callee = .optionalMember(baseExpr, name) }
            if case .optional = result { return result }
            return result == .unknown || result == .void ? result : .optional(result)
        }
        if case .member(var baseExpr, let name) = callee {
            // `Result.failed(code: 2)`: a case with associated values.
            if case .variable(let typeName) = baseExpr, case .enumType(let info)? = lookup(typeName) {
                var payload: [Argument]? = arguments
                let type = try caseType(name, &payload, expected: .named(info.name))
                arguments = payload ?? []
                return type
            }
            if case .variable(let module) = baseExpr, case .module? = lookup(module) {
                for index in arguments.indices { _ = try typeOf(&arguments[index].value, expecting: .unknown) }
                return .unknown
            }
            let base = try typeOf(&baseExpr)
            callee = .member(baseExpr, name)
            return try methodCallType(base, baseExpr: baseExpr, name, &callee, &arguments)
        }
        let type = try typeOf(&callee)
        return try apply(type, &arguments, name: "the function")
    }

    /// A call to a named function: the overload is chosen here.
    @_spi(Shell) public func call(_ overloads: [Signature], callee: inout Expr, _ arguments: inout [Argument], name: String) throws -> TypeAnnotation {
        guard let chosen = try resolve(overloads, &arguments, name: name) else {
            // Which one isn't known until it runs (an argument isn't typed yet).
            return commonReturn(overloads)
        }
        if overloads.count > 1 { callee = .chosen(callee, overload: chosen.index) }
        if chosen.isThrowing { try throwingSite("'\(name)'") }
        return chosen.returns
    }

    @_spi(Shell) public func commonReturn(_ overloads: [Signature]) -> TypeAnnotation {
        overloads.allSatisfy { $0.returns == overloads[0].returns } ? overloads[0].returns : .unknown
    }

    /// `base.name(arguments)` for a receiver of type `base`; `baseExpr` is
    /// where it came from, if it can be changed by a mutating method.
    @_spi(Shell) public func methodCallType(
        _ base: TypeAnnotation, baseExpr: Expr?, _ name: String, _ callee: inout Expr, _ arguments: inout [Argument]
    ) throws -> TypeAnnotation {
        if case .named(let structName) = base, let info = structInfo(named: structName), let methods = info.methods[name] {
            guard let chosen = try resolve(methods, &arguments, name: name) else { return commonReturn(methods) }
            if methods.count > 1 { callee = .chosen(callee, overload: chosen.index) }
            if let baseExpr, chosen.isMutating { try checkMutable(baseExpr, method: name) }
            if chosen.isThrowing { try throwingSite("'\(name)'") }
            return chosen.returns
        }
        // Swift's own methods first; then what the prelude adds for shells,
        // like `sorted(by: \.size)`.
        var bridgedError: TypeError?
        if let (bridgedType, bindings) = bridged(base), bridgedType.members.contains(where: { $0.kind == .method && !$0.isStatic && $0.name == name }) {
            var attempt = arguments
            do {
                let (type, bridgedExpr) = try bridgedCall(bridgedType.name, kind: .method, isStatic: false, receiver: baseExpr,
                                                          bindings: bindings, name: name, &attempt)
                arguments = attempt
                callee = bridgedExpr
                return type
            } catch let error as TypeError {
                bridgedError = error
            }
        }
        do {
            if let sequenceResult = try sequenceMethodType(name, on: base, &callee, &arguments) {
                return sequenceResult
            }
        } catch let error as TypeError {
            throw TypeChecker.preferred(prelude: error, swift: bridgedError)
        }
        if let bridgedError { throw bridgedError }
        let member = try memberType(of: base, name)
        return try apply(member, &arguments, name: name)
    }

    /// Calling a value of type `type`.
    @_spi(Shell) public func apply(_ type: TypeAnnotation, _ arguments: inout [Argument], name: String) throws -> TypeAnnotation {
        switch type {
        case .functionType(let parameters, let result, let throwing):
            let signature = Signature(name: name, parameters: parameters.map { Parameter(label: nil, name: "_", type: $0) },
                                      returns: result, isThrowing: throwing)
            _ = try resolve([signature], &arguments, name: name)
            if throwing { try throwingSite(name) }
            return result
        case .function, .unknown:
            for index in arguments.indices { _ = try typeOf(&arguments[index].value, expecting: .unknown) }
            return .unknown
        case .any:
            throw TypeError("an Any can't be called: cast it first, as in (value as? (Int) -> Int)")
        default:
            throw TypeError("\(type) isn't a function")
        }
    }

    /// A mutating method changes its receiver, which must be a `var` (or
    /// part of one).
    @_spi(Shell) public func checkMutable(_ base: Expr, method: String) throws {
        var root = base
        while true {
            switch root {
            case .member(let inner, _), .index(let inner, _): root = inner
            case .variable(let name):
                if case .variable(_, let mutable)? = lookup(name), !mutable {
                    throw TypeError("cannot use mutating method '\(method)' on '\(name)': it's a 'let' constant")
                }
                return
            default:
                throw TypeError("cannot use mutating method '\(method)' on a value that isn't in a variable")
            }
        }
    }
}

extension TypeChecker {
    /// When neither the prelude's method nor Swift's fits: the prelude's
    /// error, unless its overloads didn't even line up with the arguments
    /// (one was missing), when Swift's is the one that applies.
    @_spi(Shell) public static func preferred(prelude: TypeError, swift: TypeError?) -> TypeError {
        guard let swift, prelude.message.contains("missing") else { return prelude }
        return swift
    }
}
