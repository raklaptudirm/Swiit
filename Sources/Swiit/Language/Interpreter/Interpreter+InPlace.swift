import Foundation
import SwiitKit

// Changing a value where it is. A variable that holds a collection, or a struct that holds one, is changed
// by moving the part to change out of where it is, changing it, and putting it back: nothing else holds
// it meanwhile, so it isn't copied. (A copy of a whole collection for each element added would make
// building one quadratic.) Only places that are plain are changed this way: a stored property, a list
// or dictionary element. A computed property, an observer, an instance or a subscript takes the
// long way, through `update`, which copies.
//
// What keeps this working is that no copy of the value is alive while it changes: a `switch` on it, or
// a tuple made of it, would keep one, so the code here takes it apart with `if case` and `guard case`.

extension Interpreter {
    /// A step of a place, with the expressions in it worked out.
    enum PlaceStep {
        case member(String)
        case index(Value)
        case indexDefault(Value, fallback: Value)
        case unwrap
    }

    /// A place that can be changed where it is: its steps, and the type it is meant to hold.
    struct Place {
        var steps: [PlaceStep]
        var type: TypeAnnotation?
        /// What a value put there must be, if the place is a property with a type: it may be changed to fit.
        var validate: ((Value) throws -> Value)?
    }

    /// Whether evaluating `expr` twice does what evaluating it once does: so a place whose indexes are
    /// pure can be looked at first and, if it turns out not to be plain, worked out again the long way.
    func isPure(_ expr: Expr) -> Bool {
        switch expr {
        case .literal, .variable: true
        case .member(let base, _): isPure(base)
        case .unary(_, let operand): isPure(operand)
        case .binary(_, let lhs, let rhs): isPure(lhs) && isPure(rhs)
        case .forceUnwrap(let inner): isPure(inner)
        case .string(let parts):
            parts.allSatisfy { if case .expression(let inner) = $0 { isPure(inner) } else { true } }
        default: false
        }
    }

    /// `root` followed by `path` as a place that can be changed in place, or nil if it can't.
    func plainPlace(_ root: String, _ path: [Assignment.Step], op: BinaryOperator?) throws -> Place? {
        guard let scope = scopeHolding(root), let binding = scope.bindings[root], binding.special != .initializing, !binding.isComputed else { return nil }
        // Nothing the long way would evaluate first can have an effect.
        for step in path {
            switch step {
            case .index(let expr): guard isPure(expr) else { return nil }
            case .indexDefault(let key, let fallback): guard isPure(key), isPure(fallback) else { return nil }
            case .member, .unwrap: break
            case .subscripted, .optionalChain: return nil
            }
        }
        var steps: [PlaceStep] = []
        var type: TypeAnnotation?
        var validate: ((Value) throws -> Value)?
        var current = binding.value
        for step in path {
            switch step {
            case .unwrap:
                guard current != .nothing else { return nil }
                steps.append(.unwrap)
            case .member(let name):
                guard case .record(let record) = current else { return nil }
                if let structType = structType(of: record) {
                    guard structType.setters[name] == nil, structType.observers[name] == nil,
                          extensionChain(of: current).allSatisfy({ $0.setters[name] == nil }),
                          let property = structType.property(name), property.mutable else { return nil }
                    steps.append(.member(name))
                    type = property.type
                    validate = { [self] value in try self.checked(value, as: property, of: structType) }
                } else {
                    guard record[name] != nil else { return nil }
                    steps.append(.member(name))
                    type = nil
                    validate = nil
                }
                current = record[name] ?? .nothing
            case .index(let expr):
                let key = try evaluate(expr)
                switch current {
                case .list(let items):
                    guard case .int(let position) = key, items.indices.contains(position) else { return nil }
                    current = items[position]
                case .dictionary(let dictionary):
                    current = dictionary[key] ?? .nothing
                default: return nil
                }
                steps.append(.index(key))
                type = nil
                validate = nil
            case .indexDefault(let keyExpr, let fallbackExpr):
                guard case .dictionary(let dictionary) = current else { return nil }
                let key = try evaluate(keyExpr)
                let fallback = try evaluate(fallbackExpr)
                current = dictionary[key] ?? fallback
                steps.append(.indexDefault(key, fallback: fallback))
                type = nil
                validate = nil
            case .subscripted, .optionalChain:
                return nil
            }
        }
        // What a type of the program's defines for the operator, or a weak variable, is the long way's.
        if path.isEmpty, case .object(is WeakReference) = current { return nil }
        if op != nil, isDeclaredValue(current) { return nil }
        return Place(steps: steps, type: type, validate: validate)
    }

    /// Runs `body` on the value at `place` in the variable `root`, which is moved out while it runs and put
    /// back as `body` left it, however it ends.
    func withPlace<T>(_ root: String, _ place: Place, _ body: (inout Value) throws -> T) throws -> T {
        guard let scope = scopeHolding(root) else { throw RuntimeError("no variable named '\(root)'") }
        // Moved: what the variable held is held by `value` alone.
        var value = scope.bindings[root]!.value
        scope.bindings[root]!.value = .nothing
        defer { scope.bindings[root]!.value = value }
        return try descend(&value, place.steps[...], body)
    }

    private func descend<T>(_ value: inout Value, _ steps: ArraySlice<PlaceStep>, _ body: (inout Value) throws -> T) throws -> T {
        guard let step = steps.first else { return try body(&value) }
        let rest = steps.dropFirst()
        switch step {
        case .unwrap:
            return try descend(&value, rest, body)
        case .member(let name):
            guard case .record(var record) = value else { throw RuntimeError("cannot assign to '\(name)' of \(value.typeName)") }
            value = .nothing
            var field = record.takeValue(name) ?? .nothing
            defer { record[name] = field; value = .record(record) }
            return try descend(&field, rest, body)
        case .index(let key):
            if case .list = value { return try descendList(&value, key, rest, body) }
            if case .dictionary = value { return try descendDictionary(&value, key, fallback: nil, rest, body) }
            throw RuntimeError("cannot assign into \(value.typeName) by index")
        case .indexDefault(let key, let fallback):
            guard case .dictionary = value else { throw RuntimeError("'default:' goes with a dictionary") }
            return try descendDictionary(&value, key, fallback: fallback, rest, body)
        }
    }

    private func descendList<T>(_ value: inout Value, _ key: Value, _ rest: ArraySlice<PlaceStep>, _ body: (inout Value) throws -> T) throws -> T {
        guard case .list(var items) = value else { preconditionFailure() }
        guard case .int(let position) = key, items.indices.contains(position) else {
            throw RuntimeError("index \(key) is out of range for a list of \(items.count)")
        }
        value = .nothing
        var element = items[position]
        items[position] = .nothing
        defer { items[position] = element; value = .list(items) }
        return try descend(&element, rest, body)
    }

    private func descendDictionary<T>(
        _ value: inout Value, _ key: Value, fallback: Value?, _ rest: ArraySlice<PlaceStep>, _ body: (inout Value) throws -> T
    ) throws -> T {
        guard case .dictionary(var dictionary) = value else { preconditionFailure() }
        value = .nothing
        var element = dictionary[key] ?? fallback ?? .nothing
        if dictionary[key] != nil { dictionary[key] = .nothing }
        defer { dictionary[key] = element == .nothing ? nil : element; value = .dictionary(dictionary) }
        return try descend(&element, rest, body)
    }

    /// `lhs op= rhs` where the value at `slot` is changed in place when it can be: a list or a string grows.
    func applyInPlace(_ op: BinaryOperator, _ slot: inout Value, _ rhs: Value) throws {
        if op == .add {
            if case .list(var items) = slot, case .list(let more) = rhs {
                slot = .nothing
                items.append(contentsOf: more)
                slot = .list(items)
                return
            }
            if case .string(var text) = slot, case .string(let more) = rhs {
                slot = .nothing
                text.append(more)
                slot = .string(text)
                return
            }
        }
        slot = try apply(op, slot, rhs)
    }
}
