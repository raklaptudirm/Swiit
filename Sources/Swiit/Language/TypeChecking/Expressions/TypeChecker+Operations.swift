import Foundation
import SwiftSyntax

// The types of operators and of the wrappers around an expression: `try`, `await`, optional chaining.

extension TypeChecker {
    /// Operators and indexing.
    func typeOfOperation(
        _ expr: inout Expr,
        expecting expected: TypeAnnotation?
    ) throws -> TypeAnnotation {
        switch expr {
        case .unary(let op, var operand):
            let type = try typeOf(&operand, expecting: op == .not ? .bool : expected)
            expr = .unary(op, operand)
            switch (op, type) {
            case (.not, .bool), (.not, .unknown): return .bool
            case (.negate, .int), (.negate, .double), (.negate, .unknown): return type
            case (.bitNot, .int), (.bitNot, .unknown): return .int
            default:
                if case .named = type,
                    let result = userOperatorType("prefix " + op.rawValue, [type])
                {
                    return result
                }
                if op == .negate, let result = bridgedOperatorType(op.rawValue, [type]) {
                    return result
                }
                throw TypeError("'\(op.rawValue)' can't be applied to \(type)")
            }
        case .binary(let op, var lhs, var rhs):
            let type = try binaryExprType(op, &lhs, &rhs, expected: expected)
            expr = .binary(op, lhs, rhs)
            return type
        case .index(var base, var index):
            let baseType = try typeOf(&base)
            var written = [Argument(value: index)]
            if let type = try extensionSubscript(on: baseType, &written) {
                expr = .subscripted(base, written)
                return type
            }
            // A subscript a bridged type declares is a member named `subscript`, chosen by the
            // index as an overload is (a String's, by String.Index); a list's and a
            // dictionary's are the interpreter's own.
            if let (bridgedType, bindings) = bridged(baseType),
                bridgedType.members.contains(where: { $0.kind == .method && $0.name == "subscript" }
                )
            {
                var arguments = [Argument(value: index)]
                do {
                    let (type, bridgedExpr) = try bridgedCall(
                        bridgedType.name,
                        kind: .method,
                        isStatic: false,
                        receiver: base,
                        bindings: bindings,
                        name: "subscript",
                        &arguments
                    )
                    expr = bridgedExpr
                    return type
                } catch {
                    // A String has a message of its own for an index that is not a position.
                    if baseType == .string { _ = try indexType(of: baseType, &index) }
                    throw error
                }
            }
            let type = try indexType(of: baseType, &index)
            expr = .index(base, index)
            return type
        case .subscripted(var base, var arguments):
            let baseType = try typeOf(&base)
            if let type = try extensionSubscript(on: baseType, &arguments) {
                expr = .subscripted(base, arguments)
                return type
            }
            guard case .named(let structName) = baseType, let info = structInfo(named: structName)
            else {
                throw TypeError("\(baseType) can't be indexed by several values")
            }
            let type = try structSubscript(info, &arguments).type
            expr = .subscripted(base, arguments)
            return type
        case .indexDefault(var base, var key, var fallback):
            let baseType = try typeOf(&base)
            guard case .dictionary(let keyType, let scriptType) = baseType else {
                throw TypeError("'default:' goes with a dictionary's key, not \(baseType)'s index")
            }
            try expect(&key, keyType, "the key")
            try expect(&fallback, scriptType, "the default")
            expr = .indexDefault(base, key, fallback)
            return scriptType
        default:
            preconditionFailure("typeOfExpression sent this to the wrong group")
        }
    }

    /// An expression around another: an annotation, an unwrap, a cast, what the checker added.
    func typeOfWrapper(
        _ expr: inout Expr,
        expecting expected: TypeAnnotation?
    ) throws -> TypeAnnotation {
        switch expr {
        case .annotated(var inner, let type):
            let written = inner
            let actual = try typeOf(&inner, expecting: type)
            guard fits(actual, type) else {
                var error = TypeError("the value must be \(type), not \(actual)")
                error.spot = spot(of: written)
                throw error
            }
            expr = .annotated(inner, type)
            // `let s: Set = [1, 2]`: a generic type written without its arguments takes them from
            // the value.
            if case .named(let name) = type, case .generic(name, _) = actual { return actual }
            return type
        case .forceUnwrap(var inner):
            let type = try typeOf(&inner)
            expr = .forceUnwrap(inner)
            if case .optional(let wrapped) = type { return wrapped }
            if type == .unknown { return .unknown }
            throw TypeError("'!' unwraps an optional, but this is \(type)")
        case .optionalMember(var base, let name):
            let wrapped = try optionalBase(&base)
            if let (bridgedType, bindings) = bridged(wrapped),
                let (type, bridgedExpr) = try bridgedProperty(
                    bridgedType.name,
                    receiver: base,
                    bindings: bindings,
                    name
                )
            {
                expr = bridgedExpr
                if case .optional = type { return type }
                return .optional(type)
            }
            if let (arguments, type) = try dynamicMember(of: wrapped, name) {
                expr = .optionalSubscripted(base, arguments)
                if case .optional = type { return type }
                return type == .unknown ? .unknown : .optional(type)
            }
            expr = .optionalMember(base, name)
            let member = try memberType(of: wrapped, name)
            if case .optional = member { return member }
            return member == .unknown ? .unknown : .optional(member)
        case .optionalSubscripted(var base, var arguments):
            let wrapped = try optionalBase(&base)
            guard case .named(let structName) = wrapped, let info = structInfo(named: structName)
            else {
                throw TypeError("\(wrapped) can't be indexed by several values")
            }
            let element = try structSubscript(info, &arguments).type
            expr = .optionalSubscripted(base, arguments)
            if case .optional = element { return element }
            return element == .unknown ? .unknown : .optional(element)
        case .optionalIndex(var base, var index):
            let wrapped = try optionalBase(&base)
            // Typed as `base![index]` would be, then made optional.
            let element = try indexType(of: wrapped, &index)
            expr = .optionalIndex(base, index)
            if case .optional = element { return element }
            return element == .unknown ? .unknown : .optional(element)
        case .chosen(var inner, let overload):
            let type = try typeOf(&inner, expecting: expected)
            expr = .chosen(inner, overload: overload)
            return type
        case .specialized(var inner, let arguments):
            let type = try typeOf(&inner, expecting: expected)
            expr = .specialized(inner, arguments)
            return type
        case .voidValue(var inner):
            _ = try typeOf(&inner)
            expr = .voidValue(inner)
            return .void
        case .described(var inner, let type):
            _ = try typeOf(&inner)
            expr = .described(inner, type)
            return .string
        case .inoutArgument(var inner):
            let type = try typeOf(&inner, expecting: expected)
            try checkPassable(inner)
            expr = .inoutArgument(inner)
            return type
        case .cast(var inner, let type, let kind):
            let actual = try typeOf(&inner, expecting: kind == .upcast ? type : nil)
            expr = .cast(inner, type, kind)
            switch kind {
            case .upcast:
                guard fits(actual, type) else {
                    throw TypeError(
                        "'as' can't make a \(actual) a \(type); 'as?' or 'as!' check it when it runs"
                    )
                }
                return type
            case .conditional:
                if case .optional = type { return type }
                return .optional(type)
            case .forced:
                return type
            case .check:
                return .bool
            }
        default:
            preconditionFailure("typeOfExpression sent this to the wrong group")
        }
    }

    /// What `x` in `x?.name` is when it isn't nil.
    func optionalBase(_ base: inout Expr) throws -> TypeAnnotation {
        let type = try typeOf(&base)
        if case .optional(let wrapped) = type { return wrapped }
        if type == .unknown { return .unknown }
        throw TypeError("'?.' is for optionals; \(type) isn't one: use '.'")
    }
}
