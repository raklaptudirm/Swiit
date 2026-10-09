import Foundation
import SwishKit

extension TypeChecker {
    // MARK: Expressions

    /// `expr`'s type, which must fit `expected`.
    /// The expressions interpolated into a string.
    @_spi(Shell) public func checkParts(_ parts: inout [StringPart]) throws {
        for index in parts.indices {
            if case .expression(var expr) = parts[index] {
                _ = try typeOf(&expr)
                parts[index] = .expression(expr)
            }
        }
    }

    @_spi(Shell) public func expect(_ expr: inout Expr, _ expected: TypeAnnotation, _ what: String) throws {
        let type = try typeOf(&expr, expecting: expected)
        guard fits(type, expected) else {
            throw TypeError("\(what) must be \(expected), not \(type)")
        }
    }

    /// `expr`'s type, given what the context expects of it (which a literal,
    /// a closure or a `.case` takes its type from); `expr` gets what the
    /// checker decided.
    @_spi(Shell) public func typeOf(_ expr: inout Expr, expecting expected: TypeAnnotation? = nil) throws -> TypeAnnotation {
        switch expr {
        case .literal(let value):
            switch value {
            case .int where expected == .double || expected == .optional(.double):
                return .double // `let x: Double = 1`
            case .string(let text) where expected.flatMap(textLiteralType) != nil:
                // A string literal is whatever text literal type is wanted, as in
                // Swift: a Character, a Substring, a FilePath. Made now, once.
                let (name, make) = textLiteralType(expected!)!
                guard let made = make(text) else { throw TypeError("\(Value.quoted(text)) isn't a \(name) literal") }
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
                if afterImport { return .unknown }
                throw TypeError("no variable named '\(name)'")
            }
            switch symbol {
            case .variable(let type, _):
                return type
            case .functions(let overloads):
                return functionValue(name, overloads, expected: expected, expr: &expr)
            case .structType, .enumType, .module, .swiftType:
                return .unknown
            }
        case .extended(var box):
            let type = try box.node.check(in: self, expecting: expected)
            expr = .extended(box)
            return type
        case .attempt(var inner, let kind):
            let sitesBefore = throwingSites
            tryDepth += 1
            let wanted = expected.flatMap { if case .optional(let wrapped) = $0 { wrapped } else { $0 } }
            let type = try typeOf(&inner, expecting: kind == .optional ? wanted : expected)
            tryDepth -= 1
            expr = .attempt(inner, kind)
            switch kind {
            case .plain:
                if throwingSites > sitesBefore { try checkHandled("this") }
                return type
            case .forced:
                throwingSites = sitesBefore // Handled right here.
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
        case .await(var job, let throwing):
            guard let awaiting = interpreter.awaiting else { throw TypeError("there is nothing to await here") }
            if throwing { try throwingSite("awaiting a job") }
            if job != nil { try expect(&job!, awaiting.operand, "what 'await' waits for") }
            expr = .await(job, throwing: throwing)
            return awaiting.result
        case .list(var items):
            let type = try listType(&items, expected: expected)
            expr = .list(items)
            return type
        case .record(var entries):
            let type = try dictionaryType(&entries, expected: expected)
            expr = .record(entries)
            return type
        case .tuple(var elements):
            if elements.isEmpty { return .void }
            var wanted: [TypeAnnotation.TupleElement]?
            if case .tuple(let elementTypes)? = expected, elementTypes.count == elements.count { wanted = elementTypes }
            var types: [TypeAnnotation.TupleElement] = []
            for index in elements.indices {
                types.append(.init(label: elements[index].label, type: try typeOf(&elements[index].value, expecting: wanted?[index].type)))
            }
            expr = .tuple(elements)
            return .tuple(types)
        case .closure(var closure):
            let type = try closureType(&closure, expecting: expected)
            expr = .closure(closure)
            return type
        case .call(var callee, var arguments):
            let type = try callType(&callee, &arguments, expected: expected)
            // A bridged member stands for the whole call.
            if case .bridged = callee { expr = callee } else { expr = .call(callee, arguments) }
            return type
        case .bridged:
            return .unknown // Only made by the checker, after typing.
        case .member(var base, let name):
            // `Int.max`: a static member of a Swift type.
            if case .variable(let typeName) = base, case .swiftType? = lookup(typeName) {
                guard let (type, bridged) = try bridgedProperty(typeName, receiver: nil, bindings: [:], name) else {
                    throw TypeError("\(typeName) has no member '\(name)'")
                }
                expr = bridged
                return type
            }
            if !TypeChecker.namesSomething(base, in: self) {
                let baseType = try typeOf(&base)
                // Swift's own members, on the values that are Swift types.
                if let (bridgedType, bindings) = bridged(baseType),
                   let (type, bridgedExpr) = try bridgedProperty(bridgedType.name, receiver: base, bindings: bindings, name) {
                    expr = bridgedExpr
                    return type
                }
                lastMemberBase = nil
                let type = try memberType(of: baseType, name)
                expr = plainAccess(lastMemberBase, base, name) ?? .member(base, name)
                return type
            }
            lastMemberBase = nil
            let type = try memberType(&base, name)
            // A plain dynamic type's (JSON's) fields are looked up when it runs, nil if missing.
            expr = plainAccess(lastMemberBase, base, name) ?? .member(base, name)
            return type
        case .caseLiteral(let name, var arguments):
            let type = try caseType(name, &arguments, expected: expected)
            // Written out with its enum, so running it needs no context.
            if case .named(let enumName) = type, enumInfo(named: enumName) != nil {
                let member = Expr.member(.variable(enumName), name)
                expr = arguments.map { .call(member, $0) } ?? member
            } else {
                expr = .caseLiteral(name, arguments)
            }
            return type
        case .unary(let op, var operand):
            let type = try typeOf(&operand, expecting: op == .negate ? expected : .bool)
            expr = .unary(op, operand)
            switch (op, type) {
            case (.not, .bool), (.not, .unknown): return .bool
            case (.negate, .int), (.negate, .double), (.negate, .unknown): return type
            default:
                if op == .negate, let result = bridgedOperatorType(op.rawValue, [type]) { return result }
                throw TypeError("'\(op.rawValue)' can't be applied to \(type)")
            }
        case .binary(let op, var lhs, var rhs):
            let type = try binaryExprType(op, &lhs, &rhs, expected: expected)
            expr = .binary(op, lhs, rhs)
            return type
        case .index(var base, var index):
            lastMemberBase = nil
            let type = try indexType(&base, &index)
            expr = plainIndex(lastMemberBase, base, index) ?? .index(base, index)
            return type
        case .annotated(var inner, let type):
            try expect(&inner, type, "the value")
            expr = .annotated(inner, type)
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
               let (type, bridgedExpr) = try bridgedProperty(bridgedType.name, receiver: base, bindings: bindings, name) {
                expr = bridgedExpr
                if case .optional = type { return type }
                return .optional(type)
            }
            expr = plainAccess(wrapped, base, name) ?? .optionalMember(base, name)
            let member = try memberType(of: wrapped, name)
            if case .optional = member { return member }
            return member == .unknown ? .unknown : .optional(member)
        case .optionalIndex(var base, var index):
            let wrapped = try optionalBase(&base)
            if let (dynamic, _) = plainType(of: wrapped) {
                _ = try typeOf(&index)
                expr = plainIndex(wrapped, base, index)!
                return dynamic.read
            }
            // Typed as `base![index]` would be, then made optional.
            let element = try indexType(of: wrapped, &index)
            expr = .optionalIndex(base, index)
            if case .optional = element { return element }
            return element == .unknown ? .unknown : .optional(element)
        case .chosen(var inner, let overload):
            let type = try typeOf(&inner, expecting: expected)
            expr = .chosen(inner, overload: overload)
            return type
        case .voidValue(var inner):
            _ = try typeOf(&inner)
            expr = .voidValue(inner)
            return .void
        case .cast(var inner, let type, let kind):
            let actual = try typeOf(&inner, expecting: kind == .upcast ? type : nil)
            expr = .cast(inner, type, kind)
            switch kind {
            case .upcast:
                guard fits(actual, type) else {
                    throw TypeError("'as' can't make a \(actual) a \(type); 'as?' or 'as!' check it when it runs")
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
        case .filePath:
            return .string
        case .ifExpression(var node):
            let type = try ifExpressionType(&node, expected: expected)
            expr = .ifExpression(node)
            return type
        case .keyPath(let rootName, let path):
            return try keyPathType(root: rootName, path, expected: expected)
        }
    }

    /// `\.size`: its root comes from the type written, or from context
    /// (`sorted(by:)` on [FileEntry] wants a KeyPath<FileEntry, V>). Where a
    /// function is wanted, it's one, as in Swift.
    @_spi(Shell) public func keyPathType(root rootName: String?, _ path: [String], expected: TypeAnnotation?) throws -> TypeAnnotation {
        var root: TypeAnnotation?
        if let rootName {
            guard lookup(rootName) != nil else { throw TypeError("no type named '\(rootName)'") }
            root = .named(rootName)
        } else {
            if case .functionType(let parameters, _, _)? = expected, parameters.count == 1 { root = parameters[0] }
            if case .keyPath(let wanted, _)? = expected { root = wanted }
        }
        if case .functionType(let parameters, _, _)? = expected, parameters.count != 1 {
            // A key path reads one value; it can't be a function of more.
            var error = TypeError("\\.\(path.joined(separator: ".")) can't be a function of \(parameters.count) values")
            error.isArity = true
            throw error
        }
        guard var type = root, type != .unknown else {
            if expected == .unknown || root == .unknown { return .keyPath(.unknown, .unknown) }
            throw TypeError("\\.\(path.joined(separator: ".")) needs a type here; write its root, as in \\Type.\(path[0])")
        }
        let start = type
        for name in path { type = try memberType(of: type, name) }
        if case .functionType? = expected { return .functionType([start], type) }
        return .keyPath(start, type)
    }

    /// What `x` in `x?.name` is when it isn't nil.
    @_spi(Shell) public func optionalBase(_ base: inout Expr) throws -> TypeAnnotation {
        let type = try typeOf(&base)
        if case .optional(let wrapped) = type { return wrapped }
        if type == .unknown { return .unknown }
        throw TypeError("'?.' is for optionals; \(type) isn't one: use '.'")
    }

    /// A function used as a value: an overloaded one is picked by the
    /// function type wanted, as in `xs.map(double)`.
    @_spi(Shell) public func functionValue(_ name: String, _ overloads: [Signature], expected: TypeAnnotation?, expr: inout Expr) -> TypeAnnotation {
        if overloads.count == 1 { return functionType(overloads[0]) }
        guard let expected, case .functionType = expected else { return .function }
        let matching = overloads.filter { fits(functionType($0), expected) }
        guard matching.count == 1 else { return .function }
        expr = .chosen(expr, overload: matching[0].index)
        return functionType(matching[0])
    }

    @_spi(Shell) public func type(of value: Value) -> TypeAnnotation {
        switch value {
        case .nothing: .optional(.unknown)
        case .bool: .bool
        case .int: .int
        case .double: .double
        case .string: .string
        case .list(let items): .list(commonType(items.map(type(of:))) ?? .unknown)
        case .dictionary(let dictionary):
            .dictionary(commonType(dictionary.keys.map(type(of:))) ?? .unknown,
                        commonType(dictionary.values.map(type(of:))) ?? .unknown)
        case .record(let record):
            if let name = record.typeName {
                structInfo(named: name) != nil ? .named(name) : .record
            } else {
                .tuple(record.map { .init(label: Record.isPosition($0.key) ? nil : $0.key, type: type(of: $0.value)) })
            }
        case .enumValue(let value): .named(value.type.name)
        case .object(let box as SwiftValue):
            if let parameters = Bridge.types[box.typeName]?.genericParameters, !parameters.isEmpty {
                .generic(box.typeName, parameters.map { _ in .unknown })
            } else {
                .named(box.typeName)
            }
        case .object(let object as CheckedObject): object.checkedType
        case .object: .unknown
        case .function: .function
        @unknown default: .unknown
        }
    }

    /// The one type all of `types` fit, if there is one.
    @_spi(Shell) public func commonType(_ types: [TypeAnnotation]) -> TypeAnnotation? {
        guard var common = types.first else { return nil }
        for type in types.dropFirst() {
            if fits(type, common) { continue }
            if fits(common, type) { common = type; continue }
            if common == .unknown || type == .unknown { common = .unknown; continue }
            return nil
        }
        return common
    }

    @_spi(Shell) public func listType(_ items: inout [Expr], expected: TypeAnnotation?) throws -> TypeAnnotation {
        if case .list(let element)? = expected {
            for index in items.indices { try expect(&items[index], element, "a list element") }
            return .list(element)
        }
        if expected == .any {
            for index in items.indices { _ = try typeOf(&items[index]) }
            return .any
        }
        if expected == .unknown {
            // Wherever it goes takes anything: its own type if it has one.
            return .list(commonType(try elementTypes(&items)) ?? .unknown)
        }
        guard !items.isEmpty else { throw TypeError("an empty list needs a type: let xs: [Int] = []") }
        // `[1, 2.5]` is a [Double], as in Swift.
        let natural = try elementTypes(&items)
        let wantsDouble = natural.contains(.double)
        var types: [TypeAnnotation] = []
        for index in items.indices { types.append(wantsDouble ? try typeOf(&items[index], expecting: .double) : natural[index]) }
        guard let element = commonType(types) else {
            throw TypeError("a list's elements must have one type, not \(Set(types.map(\.description)).sorted().joined(separator: " and ")); write its type, like [Any]")
        }
        return .list(element)
    }

    /// The elements' own types; a `.case` or `nil` takes its type from the
    /// others, as in `[Level.high, .low]`.
    @_spi(Shell) public func elementTypes(_ items: inout [Expr]) throws -> [TypeAnnotation] {
        var types = [TypeAnnotation?](repeating: nil, count: items.count)
        for index in items.indices where TypeChecker.hasNaturalType(items[index]) || !TypeChecker.isContextual(items[index]) {
            if case .literal(.nothing) = items[index] { continue }
            types[index] = try typeOf(&items[index])
        }
        // In order, each taking its type from those typed before it, so
        // `[c ? K.a : .b, .b]` works.
        for index in items.indices where types[index] == nil {
            let known = commonType(types.compactMap { $0 })
            types[index] = try typeOf(&items[index], expecting: known.map { .optional($0) } ?? nil)
        }
        return types.map { $0! }
    }

    @_spi(Shell) public func dictionaryType(_ entries: inout [RecordEntry], expected: TypeAnnotation?) throws -> TypeAnnotation {
        if case .dictionary(let key, let value)? = expected {
            for index in entries.indices {
                try expect(&entries[index].key, key, "a key")
                try expect(&entries[index].value, value, "a value")
            }
            return .dictionary(key, value)
        }
        guard !entries.isEmpty else { throw TypeError("an empty dictionary needs a type: let d: [String: Int] = [:]") }
        var keys: [TypeAnnotation] = []
        var values: [TypeAnnotation] = []
        for index in entries.indices {
            keys.append(try typeOf(&entries[index].key))
            values.append(try typeOf(&entries[index].value))
        }
        guard let key = commonType(keys) else { throw TypeError("a dictionary's keys must have one type") }
        guard let value = commonType(values) else {
            throw TypeError("a dictionary's values must have one type, not \(Set(values.map(\.description)).sorted().joined(separator: " and ")); for a record, write a tuple, like (name: \"x\", size: 2.mb)")
        }
        return .dictionary(key, value)
    }
}
