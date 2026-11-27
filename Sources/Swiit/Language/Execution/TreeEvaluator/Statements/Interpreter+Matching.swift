import Foundation

// Matching values to patterns: `case`, `if case`, `catch` and a `switch`.

extension Interpreter {
    /// Whether `value` matches `pattern`, binding what the pattern names.
    func match(
        _ pattern: Pattern,
        _ value: Value,
        into bindings: inout [String: Binding]
    ) throws -> Bool {
        switch pattern {
        case .wildcard:
            return true
        case .binding(let name, let mutable):
            bindings[name] = Binding(value: value, mutable: mutable)
            return true
        case .enumCase(let typeName, let name, let arguments):
            guard case .enumValue(let enumValue) = value.storage else { return false }
            if let typeName {
                guard let named = enumType(named: typeName) else {
                    throw RuntimeError("no enum named \(typeName)")
                }
                guard named === enumValue.type else { return false }
            }
            guard let definition = enumValue.type.case(named: name) else {
                throw RuntimeError("\(enumValue.type.name) has no case '\(name)'")
            }
            guard enumValue.name == name else { return false }
            guard let arguments else { return true }  // `.failed` matches whatever it carries.
            guard arguments.count == enumValue.values.count else {
                throw RuntimeError(
                    "\(enumValue.type.name).\(name) has \(enumValue.values.count) associated values, not \(arguments.count)"
                )
            }
            for (index, argument) in arguments.enumerated() {
                if let label = argument.label, label != definition.labels[index] {
                    throw RuntimeError(
                        "\(enumValue.type.name).\(name)'s value #\(index + 1) isn't labeled '\(label)'"
                    )
                }
                guard try match(argument.pattern, enumValue.values[index], into: &bindings) else {
                    return false
                }
            }
            return true
        case .expression(let expr):
            // A range matches what's in it; anything else, what's equal to it.
            if case .binary(let op, let lower, let upper) = expr,
                op == .closedRange || op == .halfOpenRange
            {
                let low = try evaluate(lower)
                let high = try evaluate(upper)
                guard let number = value.asDouble, let from = low.asDouble, let to = high.asDouble
                else { return false }
                return number >= from && (op == .closedRange ? number <= to : number < to)
            }
            let expected = try evaluate(expr)
            if case .enumValue = value.storage, case .string = expected.storage {
                throw RuntimeError(
                    "can't compare \(value.typeName) with a String; match a case like .\(expected)"
                )
            }
            return value.isEqual(to: expected)
        case .cast(let inner, let type):
            guard let converted = conform(value, to: type) else { return false }
            return try match(inner, converted, into: &bindings)
        case .isType(let type):
            return conform(value, to: type) != nil
        case .some(let inner):
            return value != .nothing ? try match(inner, value, into: &bindings) : false
        case .partialRange(let lower, let upper, let closed):
            if let lower, try apply(.less, value, try evaluate(lower)) == .bool(true) {
                return false
            }
            if let upper {
                let bound = try evaluate(upper)
                return try apply(closed ? .lessEqual : .less, value, bound) == .bool(true)
            }
            return true
        case .tuple(let patterns):
            guard let record = value.record, record.typeName == nil,
                record.count == patterns.count
            else {
                return false
            }
            for (pattern, field) in zip(patterns, record) {
                guard try match(pattern, field.value, into: &bindings) else { return false }
            }
            return true
        }
    }

    /// Whether a value is an Error: of a struct or enum declared `: Error`, or
    /// what the interpreter throws (`Error`, `CancellationError`).
    func isError(_ value: Value) -> Bool {
        switch value.storage {
        case .structure(let structure):
            guard let name = structure.record.typeName else { return false }
            return name == "Error"
                || structType(named: name)?.conformances.contains("Error") == true
        case .enumValue(let enumValue):
            return enumValue.type.conformances.contains("Error")
        case .object(let instance as ClassInstance):
            return instance.type.allConformances.contains("Error")
        default:
            return false
        }
    }

    /// The first of `cases` whose pattern (and `where`) matches `subject`, and
    /// what it binds; one without patterns matches anything, binding
    /// `anyName` if given (a bare `catch` binds `error`).
    func firstMatch(
        _ cases: [SwitchCase],
        _ subject: Value,
        anyName: String? = nil
    ) throws -> (index: Int, bindings: [String: Binding])? {
        for (index, switchCase) in cases.enumerated() {
            if switchCase.patterns.isEmpty {
                return (index, anyName.map { [$0: Binding(value: subject, mutable: false)] } ?? [:])
            }
            for (position, pattern) in switchCase.patterns.enumerated() {
                var bindings: [String: Binding] = [:]
                guard try match(pattern, subject, into: &bindings) else { continue }
                // The `where` is the last pattern's, as in Swift: in `case 1, 2
                // where c:`, a 1 matches whatever c is.
                if let guardExpr = switchCase.guardExpr, position == switchCase.patterns.count - 1 {
                    scopes.append(Scope(bindings))
                    defer { scopes.removeLast() }
                    let verdict = try evaluate(guardExpr)
                    guard case .bool(let pass) = verdict.storage else {
                        throw RuntimeError("a case's where must be a Bool, not \(verdict.typeName)")
                    }
                    guard pass else { continue }
                }
                return (index, bindings)
            }
        }
        return nil
    }

    /// Runs a switch: the first case whose pattern (and `where`) matches,
    /// then on through `fallthrough`. No match is an error: Swift checks a
    /// switch covers everything when compiling; Swiit can only check here.
    func runSwitch(_ node: SwitchStatement) throws {
        let subject = try evaluate(node.subject)
        guard let start = try firstMatch(node.cases, subject) else {
            throw RuntimeError(
                "switch over \(subject.description.isEmpty ? subject.typeName : subject.description) matched no case; add one, or a default"
            )
        }

        var index = start.index
        var bindings = start.bindings
        while index < node.cases.count {
            do {
                try runBlock(node.cases[index].body, declaring: bindings)
                return
            } catch ControlFlow.fallthroughCase {
                index += 1
                bindings = [:]
            } catch ControlFlow.breakLoop(nil) {
                return  // `break` leaves the switch.
            }
        }
    }
}
