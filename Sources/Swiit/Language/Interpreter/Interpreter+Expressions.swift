import Foundation

extension Interpreter {
    // MARK: Expressions

    func evaluate(_ expr: Expr) throws -> Value {
        switch expr {
        case .literal, .string, .variable, .local, .filePath, .keyPath, .ifExpression:
            return try evaluateName(expr)
        case .list, .record, .tuple:
            return try evaluateCollection(expr)
        case .forceUnwrap, .optionalMember, .optionalIndex, .optionalSubscripted, .attempt, .await:
            return try evaluateOptional(expr)
        case .caseLiteral, .member, .call, .bridged, .closure, .childTask, .inoutArgument,
            .described, .voidValue,
            .specialized, .chosen:
            return try evaluateCallLike(expr)
        case .annotated, .unary, .binary, .index, .subscripted, .indexDefault, .cast:
            return try evaluateOperation(expr)
        }
    }

    /// Literals and names.
    private func evaluateName(_ expr: Expr) throws -> Value {
        switch expr {
        case .literal(let value):
            return value
        case .string(let parts):
            return .string(try expand(parts))
        case .local(let local):
            // Its slot holds it wherever it is read (`FrameResolver`); by name otherwise.
            guard let binding = task.frame?.binding(at: local.slot) ?? lookup(local.name) else {
                throw RuntimeError("no variable named '\(local.name)'")
            }
            let value = binding.value
            if case .object(let reference as WeakReference) = value.storage {
                return reference.target.map { .object($0) } ?? .nothing
            }
            return value
        case .variable(let name):
            guard let binding = lookup(name) else {
                throw RuntimeError("no variable named '\(name)'")
            }
            // A weak variable gives what it refers to, or nil once that is gone.
            let value = binding.value
            if case .object(let reference as WeakReference) = value.storage {
                return reference.target.map { .object($0) } ?? .nothing
            }
            return value
        case .filePath:
            return .string(file ?? "<prompt>")
        case .ifExpression(let node):
            let (branch, bindings) = try chooseBranch(node)
            guard let branch, let expr = IfStatement.branchExpression(branch) else {
                return .nothing
            }
            scopes.append(Scope(bindings))
            defer { scopes.removeLast() }
            return try evaluate(expr)
        case .keyPath(_, let path):
            return .function(KeyPathValue(path: path))
        default:
            preconditionFailure("this was sent to the wrong group")
        }
    }

    /// Lists, records and tuples.
    private func evaluateCollection(_ expr: Expr) throws -> Value {
        switch expr {
        case .list(let elements):
            return .list(try elements.map(evaluate))
        case .record(let entries):
            // `["a": 1]`: a dictionary, as in Swift.
            var dictionary: [Value: Value] = [:]
            for entry in entries {
                dictionary[try evaluate(entry.key)] = try evaluate(entry.value)
            }
            return .dictionary(dictionary)
        case .tuple(let elements):
            // `(name: "x", 2)`: unlabeled elements are keyed by position.
            var record = Value.Record()
            for (index, element) in elements.enumerated() {
                record[element.label ?? String(index)] = try evaluate(element.value)
            }
            return Value(record: record)
        default:
            preconditionFailure("this was sent to the wrong group")
        }
    }

    /// Optionals, `try`, and `await`.
    private func evaluateOptional(_ expr: Expr) throws -> Value {
        switch expr {
        case .forceUnwrap(let inner):
            let value = try evaluate(inner)
            guard value != .nothing else {
                throw RuntimeError("\(SwiftPrinter().source(inner)) is nil, but '!' needs a value")
            }
            return value
        case .optionalMember(let base, let name):
            let value = try evaluate(base)
            return value == .nothing ? .nothing : try member(name, of: value)
        case .optionalSubscripted(let base, let arguments):
            let value = try evaluate(base)
            return value == .nothing
                ? .nothing : try evaluate(.subscripted(.literal(value), arguments))
        case .optionalIndex(let base, let index):
            let value = try evaluate(base)
            guard value != .nothing else { return .nothing }
            // A struct or class with a subscript of its own is indexed as `x[i]` is.
            if value.record != nil { return try evaluate(.index(.literal(value), index)) }
            if case .object(_ as ClassInstance) = value.storage {
                return try evaluate(.index(.literal(value), index))
            }
            return try element(of: value, at: try evaluate(index))
        case .attempt(let operand, .plain):
            return try evaluate(operand)
        case .attempt(let operand, .optional):
            do {
                return try evaluate(operand)
            } catch is RuntimeError {
                return .nothing
            }
        case .attempt(let operand, .forced):
            do {
                return try evaluate(operand)
            } catch let error as RuntimeError {
                throw FatalError(error: error)
            }
        case .await(let target, _):
            // `await f()`: what the call gave. (The interpreter waits at every wait anyway.)
            return try evaluate(target)
        default:
            preconditionFailure("this was sent to the wrong group")
        }
    }

    /// Operators, indexing and casts.
    private func evaluateOperation(_ expr: Expr) throws -> Value {
        switch expr {
        case .annotated(let inner, let type):
            let value = try evaluate(inner, expecting: type)
            guard let conforming = conform(value, to: type) else {
                throw RuntimeError("expected \(type), not \(value.typeName)")
            }
            return conforming
        case .binary(let op, let lhs, let rhs):
            return try evaluateBinary(op, lhs, rhs)
        case .unary(let op, let operand):
            return try apply(op, try evaluate(operand))
        case .cast(let inner, let type, let kind):
            let value = try evaluate(inner)
            let converted = conform(value, to: type)
            switch kind {
            case .conditional: return converted ?? .nothing
            case .check: return .bool(converted != nil)
            case .upcast: return converted ?? value
            case .forced:
                guard let converted else {
                    throw RuntimeError("'as!' failed: a \(value.typeName) isn't a \(type)")
                }
                return converted
            }
        case .index(let base, let index):
            let value = try evaluate(base)
            if let record = value.record, let type = structType(of: record),
                !type.subscriptGetters.isEmpty
            {
                return try readSubscript(record, type, [Argument(value: index)])
            }
            if case .object(let instance as ClassInstance) = value.storage {
                return try readSubscript(instance, [Argument(value: index)])
            }
            return try element(of: value, at: try evaluate(index))
        case .subscripted(let base, let arguments):
            let target = try evaluate(base)
            if case .object(let instance as ClassInstance) = target.storage {
                return try readSubscript(instance, arguments)
            }
            guard let record = target.record, let type = structType(of: record),
                !type.subscriptGetters.isEmpty
            else {
                throw RuntimeError("this value has no subscript")
            }
            return try readSubscript(record, type, arguments)
        case .indexDefault(let base, let key, let fallback):
            guard case .dictionary(let dictionary) = try evaluate(base).storage else {
                throw RuntimeError("'default:' goes with a dictionary")
            }
            return try dictionary[try evaluate(key)] ?? evaluate(fallback)
        default:
            preconditionFailure("this was sent to the wrong group")
        }
    }

    /// `lhs op rhs`: a few operators look at their operands first (`&&`, `??`, a `.case` on one
    /// side); the rest evaluate both and apply.
    private func evaluateBinary(_ op: BinaryOperator, _ lhs: Expr, _ rhs: Expr) throws -> Value {
        switch op {
        case .and:
            return .bool(try truth(lhs, for: .and) && truth(rhs, for: .and))
        case .or:
            return .bool(try truth(lhs, for: .or) || truth(rhs, for: .or))
        case .coalesce:
            let value = try evaluate(lhs)
            if value == .nothing { return try evaluate(rhs) }
            return value
        case .closedRange, .halfOpenRange:
            return try makeRange(op, try evaluate(lhs), try evaluate(rhs))
        case .equal, .notEqual:
            if Interpreter.isCaseLiteral(lhs) || Interpreter.isCaseLiteral(rhs) {
                // `$0.type == .directory`: the case comes from the other side's enum.
                let known = try evaluate(Interpreter.isCaseLiteral(lhs) ? rhs : lhs)
                guard case .enumValue(let enumValue) = known.storage else {
                    throw RuntimeError(
                        "\(op.rawValue) with a .case needs an enum on the other side, not \(known.typeName)"
                    )
                }
                let literal = Interpreter.isCaseLiteral(lhs) ? lhs : rhs
                guard case .caseLiteral(let name, let arguments) = literal else {
                    preconditionFailure()
                }
                let equal = try makeCase(enumValue.type, name, arguments) == known
                return .bool(op == .equal ? equal : !equal)
            }
        case .less, .lessEqual, .greater, .greaterEqual:
            if Interpreter.isCaseLiteral(lhs) || Interpreter.isCaseLiteral(rhs) {
                // `level < .high`: the case comes from the other side's enum.
                let known = try evaluate(Interpreter.isCaseLiteral(lhs) ? rhs : lhs)
                guard case .enumValue(let enumValue) = known.storage else {
                    throw RuntimeError(
                        "\(op.rawValue) with a .case needs an enum on the other side, not \(known.typeName)"
                    )
                }
                guard
                    case .caseLiteral(let name, let arguments) = Interpreter.isCaseLiteral(lhs)
                        ? lhs : rhs
                else {
                    preconditionFailure()
                }
                let literal = try makeCase(enumValue.type, name, arguments)
                return Interpreter.isCaseLiteral(lhs)
                    ? try apply(op, literal, known) : try apply(op, known, literal)
            }
        default:
            break
        }
        return try apply(op, try evaluate(lhs), try evaluate(rhs))
    }
}
