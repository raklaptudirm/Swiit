import Foundation
import SwiftSyntax

extension TypeChecker {
    // MARK: Expressions

    /// `expr`'s type, which must fit `expected`.
    /// The expressions interpolated into a string.
    /// What is interpolated is shown as Swift shows its type's values (an
    /// optional as `Optional(5)`).
    func checkParts(_ parts: inout [StringPart]) throws {
        for index in parts.indices {
            if case .expression(var expr) = parts[index] {
                let type = try typeOf(&expr)
                if TypeChecker.isShownByType(type) { expr = .described(expr, type) }
                parts[index] = .expression(expr)
            }
        }
    }

    /// Whether showing a value of this type needs the type: one holding an
    /// optional, whose `nil` and `Optional(5)` the value alone doesn't tell.
    static func isShownByType(_ type: TypeAnnotation) -> Bool {
        switch type {
        case .optional: true
        case .list(let element): isShownByType(element)
        case .dictionary(let key, let value): isShownByType(key) || isShownByType(value)
        case .tuple(let elements): elements.contains { isShownByType($0.type) }
        case .named: true
        default: false
        }
    }

    func expect(_ expr: inout Expr, _ expected: TypeAnnotation, _ what: String) throws {
        let original = expr
        let type = try typeOf(&expr, expecting: expected)
        guard fits(type, expected) else {
            var error = TypeError("\(what) must be \(expected), not \(type)")
            error.spot = spot(of: original)
            throw error
        }
    }

    /// Where an expression of the statement being checked was written, if it can be told.
    func spot(of expression: Expr) -> SourceRange? {
        spots.first { $0.expression == expression }?.range
    }

    /// `expr`'s type, given what the context expects of it (which a literal,
    /// a closure or a `.case` takes its type from); `expr` gets what the
    /// checker decided.
    func typeOf(
        _ expr: inout Expr,
        expecting expected: TypeAnnotation? = nil
    ) throws -> TypeAnnotation {
        let original = expr
        do {
            return try typeOfExpression(&expr, expecting: expected)
        } catch var error as TypeError {
            // The innermost expression that was being typed is where the error is.
            if error.spot == nil { error.spot = spot(of: original) }
            throw error
        }
    }

    private func typeOfExpression(
        _ expr: inout Expr,
        expecting expected: TypeAnnotation?
    ) throws -> TypeAnnotation {
        switch expr {
        case .local(let local):
            // Given a slot after it was checked; typed as the variable it is.
            var named = Expr.variable(local.name)
            return try typeOfName(&named, expecting: expected)
        case .literal, .string, .variable, .filePath, .keyPath, .ifExpression:
            return try typeOfName(&expr, expecting: expected)
        case .attempt, .await, .childTask, .closure:
            return try typeOfEffect(&expr, expecting: expected)
        case .list, .record, .tuple:
            return try typeOfCollection(&expr, expecting: expected)
        case .call, .bridged, .member, .caseLiteral:
            return try typeOfCall(&expr, expecting: expected)
        case .unary, .binary, .index, .subscripted, .indexDefault:
            return try typeOfOperation(&expr, expecting: expected)
        case .annotated, .forceUnwrap, .optionalMember, .optionalIndex, .optionalSubscripted,
            .chosen,
            .specialized,
            .voidValue, .described,
            .inoutArgument, .cast:
            return try typeOfWrapper(&expr, expecting: expected)
        }
    }

    /// Literals, names, and what stands for a value by itself.
    private func typeOfName(
        _ expr: inout Expr,
        expecting expected: TypeAnnotation?
    ) throws -> TypeAnnotation {
        switch expr {
        case .literal(let value):
            switch value.storage {
            case .int where expected == .double || expected == .optional(.double):
                return .double  // `let x: Double = 1`
            case .string(let text) where expected.flatMap(textLiteralType) != nil:
                // A string literal is whatever text literal type is wanted, as in
                // Swift: a Character, a Substring, a FilePath. Made now, once.
                let (name, make) = textLiteralType(expected!)!
                guard let made = make(text) else {
                    throw TypeError("\(Value.quoted(text)) isn't a \(name) literal")
                }
                expr = .literal(made)
                return .named(name)
            case .nothing:
                if let expected, case .optional = expected { return expected }
                return .optional(.unknown)
            default:
                return type(of: value)
            }
        case .string(var parts):
            try checkParts(&parts)
            expr = .string(parts)
            return .string
        case .variable(let name):
            guard let symbol = lookup(name) else {
                // In a type's body, a name that isn't bound may be the type's own member.
                if case .variable(let selfType, _)? = lookup("self"),
                    hasMember(selfType, named: name)
                {
                    expr = .member(.variable("self"), name)
                    return try typeOf(&expr, expecting: expected)
                }
                throw TypeError("no variable named '\(name)'")
            }
            switch symbol {
            case .variable(let type, _):
                return type
            case .functions(let overloads):
                return functionValue(name, overloads, expected: expected, expr: &expr)
            case .structType(let info):
                return .metatype(.named(info.name))
            case .enumType(let info):
                return .metatype(.named(info.name))
            case .protocolType(let info):
                return .metatype(.named(info.name))
            case .swiftType(let typeName):
                return .metatype(TypeAnnotation.spelled(typeName) ?? .named(typeName))
            case .asyncLet:
                // Its task's value, which waits for it (and throws what it threw).
                let value = Bridge.types["Task"]!.members
                    .firstIndex { $0.kind == .property && !$0.isStatic && $0.name == "value" }!
                expr = .bridged(
                    type: "Task",
                    member: value,
                    receiver: .variable(name),
                    arguments: []
                )
                return try typeOf(&expr)
            }
        case .filePath:
            return .string
        case .keyPath(let rootName, let path):
            return try keyPathType(root: rootName, path, expected: expected)
        case .ifExpression(var node):
            let type = try ifExpressionType(&node, expected: expected)
            expr = .ifExpression(node)
            return type
        default:
            preconditionFailure("typeOfExpression sent this to the wrong group")
        }
    }

    /// What changes how the rest is run: `try`, `await`, a child task, a closure.
    private func typeOfEffect(
        _ expr: inout Expr,
        expecting expected: TypeAnnotation?
    ) throws -> TypeAnnotation {
        switch expr {
        case .attempt(var inner, let kind):
            let sitesBefore = throwingSites
            tryDepth += 1
            let wanted = expected.flatMap {
                if case .optional(let wrapped) = $0 { wrapped } else { $0 }
            }
            let type = try typeOf(&inner, expecting: kind == .optional ? wanted : expected)
            tryDepth -= 1
            expr = .attempt(inner, kind)
            switch kind {
            case .plain:
                if throwingSites > sitesBefore { try checkHandled("this") }
                return type
            case .forced:
                throwingSites = sitesBefore  // Handled right here.
                return type
            case .optional:
                throwingSites = sitesBefore
                if case .optional = type { return type }
                if type == .void {
                    // Success is `()`, not nil, as in Swift.
                    expr = .attempt(.voidValue(inner), kind)
                    return .optional(.void)
                }
                return .optional(type)
            }
        case .await(var operand, let throwing):
            let sitesBefore = asyncSites
            awaitDepth += 1
            let type = try typeOf(&operand, expecting: nil)
            awaitDepth -= 1
            // `await f()`: what an `async` call gives, in an async context. An `await` with nothing
            // async in it is no more than a warning in Swift, which Swiit has none of: it gives the
            // value, and may be written anywhere.
            if asyncSites > sitesBefore { try checkAwaitAllowed() }
            expr = .await(operand, throwing: throwing)
            return type
        case .childTask(var closure):
            let (result, throwing) = try childTaskType(&closure)
            expr = .childTask(closure)
            return .generic("Task", [result, .named(throwing ? "Error" : "Never")])
        case .closure(var closure):
            let type = try closureType(&closure, expecting: expected)
            expr = .closure(closure)
            return type
        default:
            preconditionFailure("typeOfExpression sent this to the wrong group")
        }
    }

    /// `\.size`: its root comes from the type written, or from context
    /// (`sorted(by:)` on [FileEntry] wants a KeyPath<FileEntry, V>). Where a
    /// function is wanted, it's one, as in Swift.
    func keyPathType(
        root rootName: String?,
        _ path: [String],
        expected: TypeAnnotation?
    ) throws -> TypeAnnotation {
        var root: TypeAnnotation?
        if let rootName {
            guard lookup(rootName) != nil else { throw TypeError("no type named '\(rootName)'") }
            root = .named(rootName)
        } else {
            if case .functionType(let parameters, _, _, _)? = expected, parameters.count == 1 {
                root = parameters[0]
            }
            if case .keyPath(let wanted, _)? = expected { root = wanted }
        }
        if case .functionType(let parameters, _, _, _)? = expected, parameters.count != 1 {
            // A key path reads one value; it can't be a function of more.
            var error = TypeError(
                "\\.\(path.joined(separator: ".")) can't be a function of \(parameters.count) values"
            )
            error.isArity = true
            throw error
        }
        guard var type = root, type != .unknown else {
            if expected == .unknown || expected == .any || root == .unknown {
                return .keyPath(.unknown, .unknown)
            }
            throw TypeError(
                "\\.\(path.joined(separator: ".")) needs a type here; write its root, as in \\Type.\(path[0])"
            )
        }
        let start = type
        for name in path { type = try memberType(of: type, name) }
        if case .functionType? = expected { return .functionType([start], type) }
        return .keyPath(start, type)
    }

    /// A function used as a value: an overloaded one is picked by the
    /// function type wanted, as in `xs.map(double)`.
    func functionValue(
        _ name: String,
        _ overloads: [Signature],
        expected: TypeAnnotation?,
        expr: inout Expr
    ) -> TypeAnnotation {
        if overloads.count == 1 { return functionType(overloads[0]) }
        guard let expected, case .functionType = expected else { return .function }
        let matching = overloads.filter { fits(functionType($0), expected) }
        guard matching.count == 1 else { return .function }
        expr = .chosen(expr, overload: matching[0].index)
        return functionType(matching[0])
    }

    func type(of value: Value) -> TypeAnnotation {
        switch value.storage {
        case .nothing: .optional(.unknown)
        case .bool: .bool
        case .int: .int
        case .double: .double
        case .string: .string
        case .list(let items): .list(commonType(items.map(type(of:))) ?? .unknown)
        case .dictionary(let dictionary):
            .dictionary(
                commonType(dictionary.keys.map(type(of:))) ?? .unknown,
                commonType(dictionary.values.map(type(of:))) ?? .unknown
            )
        case .structure(let structure):
            structInfo(named: structure.typeName) != nil ? .named(structure.typeName) : .record
        case .tuple(let tuple):
            .tuple(
                tuple.map {
                    .init(
                        label: Value.Record.isPosition($0.key) ? nil : $0.key,
                        type: type(of: $0.value)
                    )
                }
            )
        case .enumValue(let value): .named(value.type.name)
        case .object(let box as SwiftValue):
            if let parameters = Bridge.types[box.typeName]?.genericParameters, !parameters.isEmpty {
                .generic(box.typeName, parameters.map { _ in .unknown })
            } else {
                .named(box.typeName)
            }
        case .object: .unknown
        case .function: .function
        @unknown default: .unknown
        }
    }
}
