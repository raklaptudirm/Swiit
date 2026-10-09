import Foundation
import SwishKit

extension Interpreter {
    // MARK: Expressions

    @_spi(Shell) public func evaluate(_ expr: Expr) throws -> Value {
        switch expr {
        case .literal(let value):
            return value
        case .string(let parts):
            return .string(try expand(parts))
        case .variable(let name):
            guard let binding = lookup(name) else { throw RuntimeError("no variable named '\(name)'") }
            return binding.value
        case .extended(let box):
            return try box.node.evaluate(in: self)
        case .list(let elements):
            return .list(try elements.map(evaluate))
        case .record(let entries):
            // `["a": 1]`: a dictionary, as in Swift.
            var dictionary = ValueDictionary()
            for entry in entries {
                dictionary[try evaluate(entry.key)] = try evaluate(entry.value)
            }
            return .dictionary(dictionary)
        case .forceUnwrap(let inner):
            let value = try evaluate(inner)
            guard value != .nothing else {
                throw RuntimeError("\(SwiftPrinter().source(inner)) is nil, but '!' needs a value")
            }
            return value
        case .optionalMember(let base, let name):
            let value = try evaluate(base)
            return value == .nothing ? .nothing : try member(name, of: value)
        case .optionalIndex(let base, let index):
            let value = try evaluate(base)
            return value == .nothing ? .nothing : try element(of: value, at: try evaluate(index))
        case .annotated(let inner, let type):
            let value = try evaluate(inner, expecting: type)
            guard let conforming = conform(value, to: type) else {
                throw RuntimeError("expected \(type), not \(value.typeName)")
            }
            return conforming
        case .tuple(let elements):
            // `(name: "x", 2)`: unlabeled elements are keyed by position.
            var record = Record()
            for (index, element) in elements.enumerated() {
                record[element.label ?? String(index)] = try evaluate(element.value)
            }
            return .record(record)
        case .caseLiteral(let name, _):
            throw RuntimeError(".\(name) needs a type here; write the enum's name too, as in Kind.\(name)")
        case .binary(let op, let lhs, let rhs) where (op == .equal || op == .notEqual)
            && (Interpreter.isCaseLiteral(lhs) || Interpreter.isCaseLiteral(rhs)):
            // `$0.type == .directory`: the case comes from the other side's enum.
            let known = try evaluate(Interpreter.isCaseLiteral(lhs) ? rhs : lhs)
            guard case .enumValue(let enumValue) = known else {
                throw RuntimeError("\(op.rawValue) with a .case needs an enum on the other side, not \(known.typeName)")
            }
            let literal = Interpreter.isCaseLiteral(lhs) ? lhs : rhs
            guard case .caseLiteral(let name, let arguments) = literal else { preconditionFailure() }
            let equal = try makeCase(enumValue.type, name, arguments) == known
            return .bool(op == .equal ? equal : !equal)
        case .member(let base, let name):
            return try member(name, of: try evaluate(base))
        case .closure(let literal):
            return .function(Function(
                name: nil, parameters: literal.parameters, returnType: literal.returnType,
                body: .swish(literal.body), captured: captureScopes(literal.names)
            ))
        case .call(let callee, let arguments):
            // The overload the checker chose, when there's a choice.
            var callee = callee
            var overload: Int?
            if case .chosen(let inner, let index) = callee {
                callee = inner
                overload = index
            }
            let value: Value
            // `x?.f()`: nothing when `x` is nil.
            if case .optionalMember(let baseExpr, let name) = callee {
                let base = try evaluate(baseExpr)
                if base == .nothing { return .nothing }
                return try evaluate(.call(.member(.literal(base), name), arguments))
            }
            if case .member(let baseExpr, let name) = callee {
                let base = try evaluate(baseExpr)
                // `Result.failed(code: 2)`: a case with associated values.
                if case .object(let type as EnumType) = base {
                    return try makeCase(type, name, arguments)
                }
                // `Point.make(1)`: a static method.
                if case .object(let type as StructType) = base, let methods = type.staticMethods[name] {
                    return try callStatic(narrowed(methods, overload), arguments)
                }
                // `p.move(by: 1)`: a struct's method, with `p` as `self`.
                if case .record(let record) = base, record[name] == nil, let type = structType(of: record),
                   let methods = type.methods[name] {
                    return try callMethod(narrowed(methods, overload), of: base, at: baseExpr, arguments)
                }
                // `xs.sorted(by: "size")`: a sequence's method.
                if let methods = sequenceMethods[name], let items = base.sequenceItems {
                    return try commandAccess().callSequenceMethod(narrowed(methods, overload), items, arguments)
                }
                value = try member(name, of: base)
            } else {
                value = try evaluate(callee)
            }
            // `Point(x: 1, y: 2)`: a new struct.
            if case .object(let type as StructType) = value {
                return try construct(type, arguments, overload: overload)
            }
            // `Level(rawValue: 2)`: the case with that raw value, or nil.
            if case .object(let type as EnumType) = value {
                guard arguments.count == 1, arguments[0].label == "rawValue" else {
                    throw RuntimeError("\(type.name) is made from a raw value: \(type.name)(rawValue: …)")
                }
                return type.case(rawValue: try evaluate(arguments[0].value)).map(Value.enumValue) ?? .nothing
            }
            // `.case` arguments wait for their parameter's type.
            let values = try arguments.map { argument -> Argument in
                if case .caseLiteral = argument.value { return argument }
                return Argument(label: argument.label, value: .literal(try evaluate(argument.value)))
            }
            switch value {
            case .function(let set as OverloadSet):
                let (function, bindings) = try resolve(narrowed(set, overload)) { try self.bind(values, to: $0) }
                return try invoke(function, with: bindings)
            case .function(let function as Function):
                return try invoke(function, with: try bind(values, to: function).bindings)
            case .function(let native as NativeFunction):
                let function = hostFunction(native.function)
                return try invoke(function, with: try bind(values, to: function).bindings)
            case .function(let keyPath as KeyPathValue):
                guard values.count == 1 else { throw RuntimeError("a key path reads one value") }
                return try keyPath.read(from: try evaluate(values[0].value), in: self)
            default:
                throw RuntimeError("\(value.typeName) isn't a function")
            }
        case .unary(let op, let operand):
            return try apply(op, try evaluate(operand))
        case .binary(.and, let lhs, let rhs):
            return .bool(try truth(lhs, for: .and) && truth(rhs, for: .and))
        case .binary(.or, let lhs, let rhs):
            return .bool(try truth(lhs, for: .or) || truth(rhs, for: .or))
        case .attempt(let operand, .plain):
            return try evaluate(operand)
        case .bridged(let typeName, let member, let receiver, let arguments):
            return try runBridged(typeName, member, receiver: receiver, arguments)
        case .filePath:
            return .string(file ?? "<prompt>")
        case .ifExpression(let node):
            let (branch, bindings) = try chooseBranch(node)
            guard let branch, let expr = IfStatement.branchExpression(branch) else { return .nothing }
            scopes.append(Scope(bindings))
            defer { scopes.removeLast() }
            return try evaluate(expr)
        case .cast(let inner, let type, let kind):
            let value = try evaluate(inner)
            let converted = conform(value, to: type)
            switch kind {
            case .conditional: return converted ?? .nothing
            case .check: return .bool(converted != nil)
            case .upcast: return converted ?? value
            case .forced:
                guard let converted else { throw RuntimeError("'as!' failed: a \(value.typeName) isn't a \(type)") }
                return converted
            }
        case .keyPath(_, let path):
            return .function(KeyPathValue(path: path))
        case .voidValue(let operand):
            _ = try evaluate(operand)
            return .record(Record())
        case .chosen(let inner, let overload):
            // A function as a value, with the overload the checker picked.
            if case .function(let set as OverloadSet) = try evaluate(inner) {
                return .function(narrowed(set, overload))
            }
            return try evaluate(inner)
        case .attempt(let operand, .optional):
            do {
                return try evaluate(operand)
            } catch is RuntimeError {
                return .nothing
            } catch is AlreadyReported {
                return .nothing
            }
        case .attempt(let operand, .forced):
            do {
                return try evaluate(operand)
            } catch let error as RuntimeError {
                throw FatalError(error: error)
            }
        case .await(let target, let throwing):
            guard let awaiting else { throw RuntimeError("there is nothing to await here") }
            return try awaiting.perform(try target.map { try evaluate($0) }, throwing)
        case .binary(.coalesce, let lhs, let rhs):
            let value = try evaluate(lhs)
            if value == .nothing { return try evaluate(rhs) }
            // `(try? $(git config x)) ?? "vi"` is a String: the checker types
            // it so, so the Output gives its text.
            if case .object = value, let text = value.text, rhs.isStringExpression { return .string(text) }
            return value
        case .binary(let op, let lhs, let rhs) where [.less, .lessEqual, .greater, .greaterEqual].contains(op)
            && (Interpreter.isCaseLiteral(lhs) || Interpreter.isCaseLiteral(rhs)):
            // `level < .high`: the case comes from the other side's enum.
            let known = try evaluate(Interpreter.isCaseLiteral(lhs) ? rhs : lhs)
            guard case .enumValue(let enumValue) = known else {
                throw RuntimeError("\(op.rawValue) with a .case needs an enum on the other side, not \(known.typeName)")
            }
            guard case .caseLiteral(let name, let arguments) = Interpreter.isCaseLiteral(lhs) ? lhs : rhs else { preconditionFailure() }
            let literal = try makeCase(enumValue.type, name, arguments)
            return Interpreter.isCaseLiteral(lhs) ? try apply(op, literal, known) : try apply(op, known, literal)
        case .binary(let op, let lhs, let rhs) where op == .closedRange || op == .halfOpenRange:
            return try makeRange(op, try evaluate(lhs), try evaluate(rhs))
        case .binary(let op, let lhs, let rhs):
            return try apply(op, try evaluate(lhs), try evaluate(rhs))
        case .index(let base, let index):
            return try element(of: try evaluate(base), at: try evaluate(index))
        }
    }

    @_spi(Shell) public static func isCaseLiteral(_ expr: Expr) -> Bool {
        if case .caseLiteral = expr { true } else { false }
    }

    /// Record fields first, then the few members values have.
    @_spi(Shell) public func member(_ name: String, of value: Value) throws -> Value {
        if case .enumValue(let enumValue) = value, name == "rawValue" {
            guard let raw = enumValue.rawValue else { throw RuntimeError("\(enumValue.type.name) has no raw values") }
            return raw
        }
        if case .object(let type as EnumType) = value, type.case(named: name) != nil, type.member(name) == nil {
            return try makeCase(type, name, nil) // Says what values it needs.
        }
        if case .object(let type as StructType) = value, let found = try staticMember(name, of: type) { return found }
        // An unset environment variable is nil, not a missing field.
        if case .object(let object as DynamicObject) = value { return try object.read(name) }
        if case .object(let object) = value, name != "description" && name != "debugDescription" {
            if object is SwiftValue, let property = try bridgedProperty(name, of: value) { return property }
            guard let member = object.member(name) else {
                throw RuntimeError("\(object.typeName) has no member '\(name)'")
            }
            return member
        }
        // Every value has its textual form, as a CustomStringConvertible
        // does in Swift: what interpolation shows. A record's own field of
        // that name comes first.
        if name == "description" || name == "debugDescription" {
            if case .record(let record) = value, let field = record[name] { return field }
            return .string(name == "description" ? value.description : value.debugDescription)
        }
        // `pair.1`: a tuple's element by position, labeled or not.
        if case .record(let record) = value, record.typeName == nil, record[name] == nil,
           let position = Int(name), position >= 0, position < record.count {
            return Array(record)[position].value
        }
        if case .record(let record) = value, record[name] == nil, let type = structType(of: record),
           let found = try structMember(name, of: record, type) {
            return found
        }
        // Swish's own kinds, and its views of Swift's, as the checker's
        // `memberType(of:_:)` types them.
        switch (value, name) {
        case (.record(let record), _) where record[name] != nil: return record[name]!
        case (.record(let record), "count"): return .int(record.count)
        case (.record(let record), "isEmpty"): return .bool(record.count == 0)
        case (.record(let record), "keys"): return .list(record.keys.map(Value.string))
        case (.record(let record), "values"): return .list(record.map(\.value))
        case (.dictionary(let dictionary), "keys"): return .list(dictionary.keys)
        case (.dictionary(let dictionary), "values"): return .list(dictionary.values)
        case (.string(let text), "lines"):
            return .list(text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).map { .string(String($0)) })
        case (.record(let record), _):
            throw RuntimeError("\(record.typeName ?? "Record") has no field '\(name)'")
        default:
            // Swift's own properties, as a key path like `\.count` reads them.
            if let property = try bridgedProperty(name, of: value) { return property }
            throw RuntimeError("\(value.typeName) has no member '\(name)'")
        }
    }

    @_spi(Shell) public func element(of base: Value, at index: Value) throws -> Value {
        if case .object(let object as DynamicObject) = base {
            guard case .string(let name) = index else {
                throw RuntimeError("\(object.typeName) is indexed by name, not \(index.typeName)")
            }
            return try object.read(name)
        }
        if case .dictionary(let dictionary) = base {
            return dictionary[index] ?? .nothing
        }
        if case .record(let record) = base, case .string(let key) = index {
            return record[key] ?? .nothing
        }
        // A command's output is indexed by line (subscripts aren't bridged yet).
        if let output = base.commandOutput {
            return try element(of: .list(output.lines.map(Value.string)), at: index)
        }
        guard case .list(let elements) = base else {
            throw RuntimeError("\(base.typeName) can't be indexed")
        }
        guard case .int(let i) = index else {
            throw RuntimeError("a list index must be an Int, not \(index.typeName)")
        }
        guard elements.indices.contains(i) else {
            throw RuntimeError("index \(i) is out of range for a list of \(elements.count)")
        }
        return elements[i]
    }
}
