import Foundation
import SwishKit

extension Interpreter {
    // MARK: Declaring

    /// `enum Name: Raw { … }`: builds the type, checking raw values, and binds
    /// its name.
    @_spi(Shell) public func declare(_ decl: EnumDecl) throws {
        var cases: [EnumType.Case] = []
        var payloadTypes: [String: [TypeAnnotation]] = [:]
        var nextInt = 0
        var rawSeen: Set<Value> = []
        for enumCase in decl.cases {
            var raw: Value?
            if let rawType = decl.rawType {
                guard enumCase.associated.isEmpty else {
                    throw RuntimeError("\(decl.name).\(enumCase.name): an enum with raw values can't have associated values")
                }
                if let expr = enumCase.rawValue {
                    let value = try evaluate(expr)
                    guard let conforming = value.conforming(to: rawType) else {
                        throw RuntimeError("\(decl.name).\(enumCase.name)'s raw value must be \(rawType), not \(value.typeName)")
                    }
                    raw = conforming
                } else {
                    switch rawType {
                    case .int: raw = .int(nextInt)
                    case .string: raw = .string(enumCase.name)
                    default: throw RuntimeError("\(decl.name).\(enumCase.name) needs a raw value")
                    }
                }
                if case .int(let n) = raw { nextInt = n + 1 }
                guard rawSeen.insert(raw!).inserted else {
                    throw RuntimeError("\(decl.name).\(enumCase.name): raw value \(raw!) is used twice")
                }
            } else if enumCase.rawValue != nil {
                throw RuntimeError("\(decl.name).\(enumCase.name): only an enum with a raw type, like `enum \(decl.name): Int`, has raw values")
            }
            cases.append(EnumType.Case(name: enumCase.name, rawValue: raw, labels: enumCase.associated.map(\.label)))
            payloadTypes[enumCase.name] = enumCase.associated.map(\.type)
        }
        let type = EnumType(name: decl.name, cases: cases)
        enumPayloadTypes[ObjectIdentifier(type)] = payloadTypes
        enumConformances[ObjectIdentifier(type)] = decl.conformances
        scopes[scopes.count - 1].bindings[decl.name] = Binding(value: .object(type), mutable: false)
    }

    /// The enum a type annotation names, looking through optionals.
    @_spi(Shell) public func enumType(for type: TypeAnnotation?) -> EnumType? {
        switch type {
        case .named(let name)?: enumType(named: name)
        case .optional(let wrapped)?: enumType(for: wrapped)
        default: nil
        }
    }

    @_spi(Shell) public func enumType(named name: String) -> EnumType? {
        guard case .object(let type as EnumType)? = lookup(name)?.value else { return nil }
        return type
    }

    // MARK: Making cases

    /// `Kind.file`, `.failed(code: 2)` or `Kind.failed(code: 2)` for `type`:
    /// checks the case exists and its associated values' labels and types.
    @_spi(Shell) public func makeCase(_ type: EnumType, _ name: String, _ arguments: [Argument]?) throws -> Value {
        guard let definition = type.case(named: name) else {
            throw RuntimeError("\(type.name) has no case '\(name)'")
        }
        let written = "\(type.name).\(name)"
        guard let arguments else {
            guard definition.labels.isEmpty else {
                let labels = definition.labels.map { ($0 ?? "_") + ":" }.joined()
                throw RuntimeError("\(written) needs its associated values: \(written)(\(labels))")
            }
            return .enumValue(EnumValue(type: type, name: name))
        }
        guard !definition.labels.isEmpty else { throw RuntimeError("\(written) has no associated values") }
        guard arguments.count == definition.labels.count else {
            throw RuntimeError("\(written) has \(definition.labels.count) associated values, not \(arguments.count)")
        }
        let types = enumPayloadTypes[ObjectIdentifier(type)]?[name] ?? []
        var values: [Value] = []
        for (index, argument) in arguments.enumerated() {
            guard argument.label == definition.labels[index] else {
                let expected = definition.labels[index].map { "'\($0):'" } ?? "no label"
                throw RuntimeError("\(written): value #\(index + 1) needs \(expected)")
            }
            let type = index < types.count ? types[index] : .any
            let value = try evaluate(argument.value, expecting: type)
            guard let conforming = conform(value, to: type) else {
                throw RuntimeError("\(written): value #\(index + 1) must be \(type), not \(value.typeName)")
            }
            values.append(conforming)
        }
        return .enumValue(EnumValue(type: type, name: name, values: values))
    }

    /// An expression whose type is known from context: a `.case` literal
    /// becomes a case of the expected enum.
    @_spi(Shell) public func evaluate(_ expr: Expr, expecting type: TypeAnnotation?) throws -> Value {
        if case .caseLiteral(let name, let arguments) = expr, let enumType = enumType(for: type) {
            return try makeCase(enumType, name, arguments)
        }
        return try evaluate(expr)
    }

    /// `value` as `type`, knowing the enums in scope; nil if it doesn't fit.
    @_spi(Shell) public func conform(_ value: Value, to type: TypeAnnotation) -> Value? {
        switch type {
        case .named(let name):
            // A plain dynamic type (parsed JSON) is whatever it parsed as.
            if dynamicTypes[name]?.plain?.standsForAnything == true { return value }
            // A Swift value, boxed, is of its Swift type.
            if case .object(let box as SwiftValue) = value, box.typeName == name { return value }
            if case .record(let record) = value, record.typeName == name, structType(named: name) != nil {
                return value
            }
            guard case .enumValue(let enumValue) = value, let expected = enumType(named: name),
                  enumValue.type === expected else { return nil }
            return value
        case .generic(let name, _):
            // A Swift value, boxed, is of its Swift type.
            if case .object(let box as SwiftValue) = value, box.typeName == name { return value }
            return nil
        case .someSequence:
            // Any sequence; the glue takes its items.
            return value
        case .optional(let wrapped):
            return value == .nothing ? value : conform(value, to: wrapped)
        case .list(let element):
            guard case .list(let items) = value else { return value.conforming(to: type) }
            var converted: [Value] = []
            for item in items {
                guard let conforming = conform(item, to: element) else { return nil }
                converted.append(conforming)
            }
            return .list(converted)
        default:
            return value.conforming(to: type)
        }
    }

    /// A case from the command line: its name (`directory` or `.directory`),
    /// or its raw value.
    @_spi(Shell) public func enumCase(fromText text: String, _ type: EnumType) -> Value? {
        let name = text.hasPrefix(".") ? String(text.dropFirst()) : text
        if let definition = type.case(named: name), definition.labels.isEmpty {
            return .enumValue(EnumValue(type: type, name: name))
        }
        return type.cases.first { $0.labels.isEmpty && $0.rawValue?.description == text }
            .map { .enumValue(EnumValue(type: type, name: $0.name)) }
    }

    // MARK: Matching

    /// Whether `value` matches `pattern`, binding what the pattern names.
    @_spi(Shell) public func match(_ pattern: Pattern, _ value: Value, into bindings: inout [String: Binding]) throws -> Bool {
        switch pattern {
        case .wildcard:
            return true
        case .binding(let name, let mutable):
            bindings[name] = Binding(value: value, mutable: mutable)
            return true
        case .enumCase(let typeName, let name, let arguments):
            guard case .enumValue(let enumValue) = value else { return false }
            if let typeName {
                guard let named = enumType(named: typeName) else { throw RuntimeError("no enum named \(typeName)") }
                guard named === enumValue.type else { return false }
            }
            guard let definition = enumValue.type.case(named: name) else {
                throw RuntimeError("\(enumValue.type.name) has no case '\(name)'")
            }
            guard enumValue.name == name else { return false }
            guard let arguments else { return true } // `.failed` matches whatever it carries.
            guard arguments.count == enumValue.values.count else {
                throw RuntimeError("\(enumValue.type.name).\(name) has \(enumValue.values.count) associated values, not \(arguments.count)")
            }
            for (index, argument) in arguments.enumerated() {
                if let label = argument.label, label != definition.labels[index] {
                    throw RuntimeError("\(enumValue.type.name).\(name)'s value #\(index + 1) isn't labeled '\(label)'")
                }
                guard try match(argument.pattern, enumValue.values[index], into: &bindings) else { return false }
            }
            return true
        case .expression(let expr):
            // A range matches what's in it; anything else, what's equal to it.
            if case .binary(let op, let lower, let upper) = expr, op == .closedRange || op == .halfOpenRange {
                let low = try evaluate(lower)
                let high = try evaluate(upper)
                guard let number = value.asDouble, let from = low.asDouble, let to = high.asDouble else { return false }
                return number >= from && (op == .closedRange ? number <= to : number < to)
            }
            let expected = try evaluate(expr)
            if case .enumValue = value, case .string = expected {
                throw RuntimeError("can't compare \(value.typeName) with a String; match a case like .\(expected)")
            }
            if case .object = value, let text = value.text { return Value.string(text).isEqual(to: expected) }
            return value.isEqual(to: expected)
        }
    }

    /// Runs a switch: the first case whose pattern (and `where`) matches,
    /// then on through `fallthrough`. No match is an error: Swift checks a
    /// switch covers everything when compiling; Swish can only check here.
    @_spi(Shell) public func runSwitch(_ node: SwitchStatement) throws -> Int32 {
        let subject = try evaluate(node.subject)
        var start: (index: Int, bindings: [String: Binding])?
        search: for (index, switchCase) in node.cases.enumerated() {
            if switchCase.patterns.isEmpty {
                start = (index, [:])
                break
            }
            for pattern in switchCase.patterns {
                var bindings: [String: Binding] = [:]
                guard try match(pattern, subject, into: &bindings) else { continue }
                if let guardExpr = switchCase.guardExpr {
                    scopes.append(Scope(bindings))
                    defer { scopes.removeLast() }
                    let verdict = try evaluate(guardExpr)
                    guard case .bool(let pass) = verdict else {
                        throw RuntimeError("a case's where must be a Bool, not \(verdict.typeName)")
                    }
                    guard pass else { continue }
                }
                start = (index, bindings)
                break search
            }
        }
        guard let start else {
            throw RuntimeError("switch over \(subject.description.isEmpty ? subject.typeName : subject.description) matched no case; add one, or a default")
        }

        var index = start.index
        var bindings = start.bindings
        var status: Int32 = 0
        while index < node.cases.count {
            do {
                status = try runBlock(node.cases[index].body, declaring: bindings)
                return status
            } catch ControlFlow.fallthroughCase {
                index += 1
                bindings = [:]
            } catch ControlFlow.breakLoop {
                return status // `break` leaves the switch.
            }
        }
        return status
    }
}

extension Interpreter {
    /// A case of an enum the prelude or the standard library module
    /// declares: `FileType.directory`.
    @_spi(Shell) public func declaredCase(_ type: String, _ name: String) -> Value {
        .enumValue(EnumValue(type: enumType(named: type)!, name: name))
    }
}
