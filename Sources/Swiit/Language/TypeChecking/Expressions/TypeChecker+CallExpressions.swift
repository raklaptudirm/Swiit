import Foundation
import SwiftSyntax

// The type of a call: which function it means and what it gives.

extension TypeChecker {
    /// Calls, bridged members, and member access.
    func typeOfCall(
        _ expr: inout Expr,
        expecting expected: TypeAnnotation?
    ) throws -> TypeAnnotation {
        switch expr {
        case .call(var callee, var arguments):
            let type = try callType(&callee, &arguments, expected: expected)
            // A bridged member stands for the whole call.
            // (A subscript's read is a value, and what is called.)
            if case .bridged = callee, callee.subscriptPlace == nil {
                expr = callee
            } else {
                expr = .call(callee, arguments)
            }
            return type
        case .bridged(let typeName, let index, var receiver, var arguments):
            // Made by the checker, and typed again when what holds it is (an
            // operator's overloads, each tried): the same type, the same effects.
            guard let member = Bridge.types[typeName]?.members[index] else { return .unknown }
            var bindings: [String: TypeAnnotation] = [:]
            if var base = receiver {
                // `async let x`'s reads: `x` itself is the task.
                if case .variable(let name) = base, case .asyncLet(let task)? = lookup(name) {
                    bindings = bridged(task)?.1 ?? [:]
                } else {
                    bindings = bridged(try typeOf(&base))?.1 ?? [:]
                    receiver = base
                }
            }
            var type = substitute(member.returns, bindings)
            var throwing = member.isThrowing
            if member.kind != .property {
                let signature = Signature(
                    name: member.name,
                    parameters: member.parameters,
                    returns: member.returns,
                    isThrowing: member.isThrowing,
                    isRethrowing: member.isRethrowing,
                    generics: member.generics
                )
                let matched = try match(&arguments, to: signature, bindings: bindings)
                (type, throwing) = (matched.returns, matched.throwing)
            }
            try bridgedEffects(member, bindings: bindings, throwing: throwing, "'\(member.name)'")
            expr = .bridged(type: typeName, member: index, receiver: receiver, arguments: arguments)
            return type
        case .member(var base, let name):
            // `Int.max`: a static member of a Swift type.
            if case .variable(let typeName) = base, case .swiftType? = lookup(typeName) {
                return try swiftStaticMember(typeName, name, &expr)
            }
            if !TypeChecker.namesSomething(base, in: self) {
                let baseType = try typeOf(&base)
                // Swift's own members, on the values that are Swift types.
                if let (bridgedType, bindings) = bridged(baseType),
                    let (type, bridgedExpr) = try bridgedProperty(
                        bridgedType.name,
                        receiver: base,
                        bindings: bindings,
                        name
                    )
                {
                    expr = bridgedExpr
                    return type
                }
                try actorSite(baseType, base, name)
                if let (arguments, type) = try dynamicMember(of: baseType, name) {
                    expr = .subscripted(base, arguments)
                    return type
                }
                let type = try memberType(of: baseType, name)
                expr = .member(base, name)
                return type
            }
            let type = try memberType(&base, name)
            expr = .member(base, name)
            return type
        case .caseLiteral(let name, var arguments):
            // `.none` and `.some(x)`, where an optional is wanted. An optional is not an enum at
            // run time: nil is `.nothing` and a present value is itself, so these two cases are
            // rewritten here to that representation (and in `checkPattern`, for patterns), not
            // declared like an enum's.
            if case .optional(let wrapped)? = expected {
                if name == "none", arguments == nil {
                    expr = .literal(.nothing)
                    return .optional(wrapped)
                }
                if name == "some", var payload = arguments, payload.count == 1 {
                    try expect(&payload[0].value, wrapped, "the wrapped value")
                    expr = .call(.variable(InternalName.some), payload)
                    return .optional(wrapped)
                }
            }
            let type = try caseType(name, &arguments, expected: expected)
            // Written out with its enum, so running it needs no context.
            var enumTypeName: String?
            if case .named(let enumName) = type { enumTypeName = enumName }
            if case .generic(let enumName, _) = type { enumTypeName = enumName }
            if let enumName = enumTypeName, enumInfo(named: enumName) != nil {
                let member = Expr.member(.variable(enumName), name)
                expr = arguments.map { .call(member, $0) } ?? member
            } else {
                expr = .caseLiteral(name, arguments)
            }
            return type
        default:
            preconditionFailure("typeOfExpression sent this to the wrong group")
        }
    }
}

extension TypeChecker {
    /// `Int.max`, or a static property an extension adds: the type of `name` on the Swift type
    /// named, with `expr` made the bridged member if it is one.
    func swiftStaticMember(
        _ typeName: String,
        _ name: String,
        _ expr: inout Expr
    ) throws -> TypeAnnotation {
        if case .property(let property)? = describe(named: typeName)?.staticMember(name) {
            return property.type
        }
        guard
            let (type, bridged) = try bridgedProperty(typeName, receiver: nil, bindings: [:], name)
        else {
            throw TypeError("\(typeName) has no member '\(name)'")
        }
        expr = bridged
        return type
    }
}
