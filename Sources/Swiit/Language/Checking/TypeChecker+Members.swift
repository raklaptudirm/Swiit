import Foundation
import SwishKit

extension TypeChecker {
    // MARK: Sequence methods

    /// `xs.filter { … }` and the rest: the prelude's `extension Sequence`,
    /// with `Element` the receiver's items' type.
    @_spi(Shell) public func sequenceMethodType(
        _ name: String, on base: TypeAnnotation, _ callee: inout Expr, _ arguments: inout [Argument]
    ) throws -> TypeAnnotation? {
        guard let methods = interpreter.sequenceMethods[name], let element = sequenceElement(base) else { return nil }
        // `select`'s result is a tuple of the fields it names, which Swift could
        // only type with parameter packs over key paths; until then its rule is
        // here (Docs/Design/foundations.md, open questions).
        if name == "select" { return try selectType(element, arguments: &arguments) }
        let candidates = sequenceSignatures(methods)
        guard let chosen = try resolve(candidates, &arguments, name: name, bindings: ["Element": element]) else {
            return commonReturn(candidates)
        }
        if candidates.count > 1 { callee = .chosen(callee, overload: chosen.index) }
        if chosen.isThrowing { try throwingSite("'\(name)'") }
        return chosen.returns
    }

    /// A sequence method's signature as it's called: without the `@input`
    /// the sequence comes in by.
    @_spi(Shell) public func sequenceSignatures(_ methods: OverloadSet) -> [Signature] {
        methods.candidates.enumerated().map { index, method in
            var signature = signature(method)
            signature.parameters.removeAll(where: \.isInput)
            signature.index = index
            return signature
        }
    }

    /// The type of a sequence's items, for its methods; nil if it isn't one.
    @_spi(Shell) public func sequenceElement(_ type: TypeAnnotation) -> TypeAnnotation? {
        if case .named(let name) = type, let element = Bridge.types[name]?.associatedTypes["Element"] { return element }
        if case .generic = type { return bridgedElement(type) }
        return switch type {
        case .list(let element): element
        case .named where plainType(of: type) != nil: plainType(of: type)!.plain.element // An array's elements, or the value itself.
        case .unknown: .unknown
        default: nil
        }
    }

    /// `select name size` on [FileEntry]: [(name: String, size: FileSize)],
    /// a tuple of the fields picked, which Swift's generics can't say.
    @_spi(Shell) public func selectType(_ element: TypeAnnotation, arguments: inout [Argument]) throws -> TypeAnnotation {
        var fields: [TypeAnnotation.TupleElement] = []
        for index in arguments.indices {
            try expect(&arguments[index].value, .string, "select: a field's name")
            guard case .literal(.string(let field)) = arguments[index].value else { return .list(.unknown) }
            fields.append(.init(label: field, type: element == .unknown ? .unknown : try memberType(of: element, field)))
        }
        return .list(.tuple(fields))
    }
}

extension TypeChecker {
    // MARK: Swift's members

    /// The Swift type a Swish type is, with its generic parameters bound:
    /// `[Int]` is Array with Element Int.
    @_spi(Shell) public func bridged(_ type: TypeAnnotation) -> (BridgedType, [String: TypeAnnotation])? {
        Bridge.type(of: type)
    }

    /// Whether a bridged type, with its generic parameters bound, conforms
    /// to `proto`: a ClosedRange<Int> is a Sequence, a ClosedRange<Double>
    /// isn't.
    @_spi(Shell) public func bridgedConforms(_ bridgedType: BridgedType, _ bindings: [String: TypeAnnotation], to proto: String) -> Bool {
        guard let needs = bridgedType.conformances[proto] else { return proto == "CustomStringConvertible" }
        return needs.allSatisfy { parameter, protocols in
            protocols.allSatisfy { conforms(bindings[parameter] ?? .unknown, to: $0) }
        }
    }

    /// The Element of a bridged Swift type that's a Sequence: Int for a
    /// ClosedRange<Int>, Character for a Substring; nil if it isn't one.
    @_spi(Shell) public func bridgedElement(_ type: TypeAnnotation) -> TypeAnnotation? {
        // A `Flow` isn't a Sequence, its reading can throw, but passes on its elements the same.
        if case .generic("Flow", let arguments) = type, arguments.count == 1 { return arguments[0] }
        guard let (bridgedType, bindings) = bridged(type), bridgedConforms(bridgedType, bindings, to: "Sequence") else { return nil }
        guard let element = bridgedType.associatedTypes["Element"]
            ?? (bridgedType.genericParameters.contains("Element") ? .parameter("Element") : nil) else { return nil }
        return substitute(element, bindings)
    }

    /// What a Swift parameter taking any sequence gets from a value of
    /// `type`: a String's Characters, a dictionary's (key, value) pairs.
    @_spi(Shell) public func anySequenceElement(_ type: TypeAnnotation) -> TypeAnnotation? {
        type == .unknown ? .unknown : bridgedElement(type) ?? (try? elementType(of: type)) ?? nil
    }

    /// A bridged property, `"abc".count` or `Int.max`, as a lookup the
    /// interpreter runs; nil if the type has no such property.
    @_spi(Shell) public func bridgedProperty(
        _ typeName: String, receiver: Expr?, bindings: [String: TypeAnnotation], _ name: String
    ) throws -> (TypeAnnotation, Expr)? {
        guard let bridgedType = Bridge.types[typeName],
              let index = bridgedType.members.firstIndex(where: {
                  $0.kind == .property && $0.name == name && $0.isStatic == (receiver == nil)
              }) else { return nil }
        let type = substitute(bridgedType.members[index].returns, bindings)
        return (type, .bridged(type: typeName, member: index, receiver: receiver, arguments: []))
    }

    /// A bridged method or initializer called with `arguments`: the overload
    /// is chosen here, and the call written as the member it is.
    @_spi(Shell) public func bridgedCall(
        _ typeName: String, kind: BridgedMember.Kind, isStatic: Bool, receiver: Expr?, bindings: [String: TypeAnnotation],
        name: String, _ arguments: inout [Argument]
    ) throws -> (TypeAnnotation, Expr) {
        guard let bridgedType = Bridge.types[typeName] else { throw TypeError("no Swift type named \(typeName)") }
        let candidates = bridgedType.members.enumerated().filter {
            $0.element.kind == kind && $0.element.name == name && $0.element.isStatic == isStatic
        }.map { index, member in
            Signature(name: kind == .initializer ? typeName : name, parameters: member.parameters, returns: member.returns,
                      isThrowing: member.isThrowing, isRethrowing: member.isRethrowing, index: index, generics: member.generics)
        }
        guard !candidates.isEmpty else {
            throw TypeError(kind == .initializer ? "\(typeName) can't be made this way from Swish yet" : "\(typeName) has no member '\(name)'")
        }
        var chosen = try resolve(candidates, &arguments, name: candidates[0].name, bindings: bindings)
        if chosen == nil, candidates.count == 1 { chosen = candidates[0] }
        guard let chosen else {
            throw TypeError("\(candidates[0].name): which overload isn't clear until the arguments' types are known")
        }
        if chosen.isThrowing { try throwingSite("'\(name)'") }
        if bridgedType.members[chosen.index].isMutating {
            // `xs.append(1)` changes xs, which must be a `var`.
            guard let receiver else { throw TypeError("\(typeName).\(name) is mutating: call it on a variable") }
            try checkMutable(receiver, method: name)
        }
        return (chosen.returns, .bridged(type: typeName, member: chosen.index, receiver: receiver, arguments: arguments))
    }

    /// The initializer of `typeName` taking one unlabeled `from`, if any.
    /// The bridged type a string literal can be where `expected` is wanted:
    /// one that's ExpressibleByStringLiteral, or an optional of one.
    @_spi(Shell) public func textLiteralType(_ expected: TypeAnnotation) -> (String, (String) -> Value?)? {
        switch expected {
        case .named(let name): Bridge.types[name]?.literal.map { (name, $0) }
        case .optional(let wrapped): textLiteralType(wrapped)
        default: nil
        }
    }

    /// Whether `expr` is a name that isn't a value: a type, `env`, a module.
    @_spi(Shell) public static func namesSomething(_ expr: Expr, in checker: TypeChecker) -> Bool {
        guard case .variable(let name) = expr else { return false }
        switch checker.lookup(name) {
        case .enumType?, .module?, .swiftType?, .structType?: return true
        default: return false
        }
    }
}

extension TypeChecker {
    // MARK: Members

    @_spi(Shell) public func memberType(_ baseExpr: inout Expr, _ name: String) throws -> TypeAnnotation {
        if case .variable(let typeName) = baseExpr, let symbol = lookup(typeName) {
            switch symbol {
            case .enumType(let info):
                // What Swift synthesizes for an enum: `allCases` and
                // `rawValue`. A Swish enum isn't a Swift type the bridge
                // could describe, so they're made here.
                if name == "allCases" {
                    guard info.cases.allSatisfy({ $0.payload.isEmpty }) else {
                        throw TypeError("\(info.name) has no allCases: some cases have associated values")
                    }
                    return .list(.named(info.name))
                }
                var none: [Argument]?
                return try caseType(name, &none, expected: .named(info.name))
            case .structType(let info):
                if let property = info.staticProperty(name) { return property.type ?? .unknown }
                if let methods = info.staticMethods[name] { return methods.count == 1 ? functionType(methods[0]) : .function }
                throw TypeError("\(info.name) has no static member '\(name)'")
            case .module:
                return .unknown
            default:
                break
            }
        }
        return try memberType(of: try typeOf(&baseExpr), name)
    }

    @_spi(Shell) public func memberType(of base: TypeAnnotation, _ name: String) throws -> TypeAnnotation {
        if let dynamic = dynamicType(of: base) { return dynamic.read }
        lastMemberBase = base
        if let (dynamic, plain) = plainType(of: base) {
            return plain.views[name] ?? dynamic.read
        }
        // Every value has its textual form, as interpolation shows it; a
        // struct's own property of that name comes first.
        if name == "description" || name == "debugDescription" {
            if case .named(let structName) = base, let info = structInfo(named: structName),
               let property = info.property(name) { return property.type ?? .unknown }
            return .string
        }
        // Swift's own properties, as in `\.count`.
        if let (bridgedType, bindings) = bridged(base),
           let property = bridgedType.members.first(where: { $0.kind == .property && !$0.isStatic && $0.name == name }) {
            return substitute(property.returns, bindings)
        }
        switch base {
        case .unknown, .record:
            return .unknown
        case .any:
            throw TypeError("an Any has no members: cast it first, as in (value as? T)?.\(name)")
        case .optional:
            throw TypeError("\(base) might be nil: unwrap it (if let, ??, ?. or !) before using .\(name)")
        case .named(let typeName):
            if let info = structInfo(named: typeName) {
                if let property = info.property(name) { return property.type ?? .unknown }
                if let computed = info.computed[name] { return computed }
                if let methods = info.methods[name] { return methods.count == 1 ? functionType(methods[0]) : .function }
                throw TypeError("\(typeName) has no member '\(name)'")
            }
            if let info = enumInfo(named: typeName) {
                if name == "rawValue" {
                    guard let raw = info.rawType else { throw TypeError("\(typeName) has no raw values") }
                    return raw
                }
                throw TypeError("\(typeName) has no member '\(name)'")
            }
            if let members = interpreter.objectMembers[typeName] {
                guard let type = members[name] else { throw TypeError("\(typeName) has no member '\(name)'") }
                return type
            }
            if Bridge.types[typeName] != nil { throw TypeError("\(typeName) has no member '\(name)'") }
            return .unknown
        case .tuple(let elements):
            guard let element = tupleElement(name, of: elements) else { throw TypeError("\(base) has no element '\(name)'") }
            return element
        default:
            break
        }
        // Swish's own kinds, and the views it gives Swift's: until step 4
        // of the foundations makes them Swift types, their members are here
        // and in the interpreter's `member(_:of:)`.
        let members: [String: TypeAnnotation]
        switch base {
        case .dictionary(let key, let value):
            // Arrays in the dictionary's order, not Swift's unordered views.
            members = ["keys": .list(key), "values": .list(value)]
        case .string:
            members = ["lines": .list(.string)]
        default:
            members = [:]
        }
        guard let type = members[name] else { throw TypeError("\(base) has no member '\(name)'") }
        return type
    }

    @_spi(Shell) public func tupleElement(_ name: String, of elements: [TypeAnnotation.TupleElement]) -> TypeAnnotation? {
        if let position = Int(name), elements.indices.contains(position) { return elements[position].type }
        return elements.first { $0.label == name }?.type
    }

    @_spi(Shell) public func caseType(_ name: String, _ arguments: inout [Argument]?, expected: TypeAnnotation?) throws -> TypeAnnotation {
        var target = expected
        if case .optional(let wrapped)? = target { target = wrapped }
        guard let target, target != .unknown, target != .any else {
            if target == nil { throw TypeError(".\(name) needs a type here; write the enum's name too, as in Kind.\(name)") }
            for index in (arguments ?? []).indices { _ = try typeOf(&arguments![index].value, expecting: .unknown) }
            return .unknown
        }
        guard case .named(let enumName) = target, let info = enumInfo(named: enumName) else {
            throw TypeError(".\(name) is a case, but a \(target) is wanted here")
        }
        guard let payload = info.payload(of: name) else { throw TypeError("\(enumName) has no case '\(name)'") }
        guard arguments != nil else {
            guard payload.isEmpty else {
                let labels = payload.map { ($0.label ?? "_") + ":" }.joined()
                throw TypeError("\(enumName).\(name) needs its associated values: \(enumName).\(name)(\(labels))")
            }
            return .named(enumName)
        }
        guard !payload.isEmpty else { throw TypeError("\(enumName).\(name) has no associated values") }
        guard arguments!.count == payload.count else {
            throw TypeError("\(enumName).\(name) has \(payload.count) associated values, not \(arguments!.count)")
        }
        for index in arguments!.indices {
            guard arguments![index].label == payload[index].label else {
                let wanted = payload[index].label.map { "'\($0):'" } ?? "no label"
                throw TypeError("\(enumName).\(name): value #\(index + 1) needs \(wanted)")
            }
            try expect(&arguments![index].value, payload[index].type, "\(enumName).\(name): value #\(index + 1)")
        }
        return .named(enumName)
    }

    @_spi(Shell) public func indexType(_ baseExpr: inout Expr, _ index: inout Expr) throws -> TypeAnnotation {
        return try indexType(of: try typeOf(&baseExpr), &index)
    }

    /// Indexing a value of type `base` with `index`.
    @_spi(Shell) public func indexType(of base: TypeAnnotation, _ index: inout Expr) throws -> TypeAnnotation {
        lastMemberBase = base
        if let dynamic = dynamicType(of: base) {
            try expect(&index, .string, "\(base)'s member name")
            return dynamic.read
        }
        if let (dynamic, _) = plainType(of: base) {
            let key = try typeOf(&index)
            guard key == .string || key == .int || key == .unknown else {
                throw TypeError("\(base) is indexed by a String (a field) or an Int (an element), not \(key)")
            }
            return dynamic.read
        }
        switch base {
        case .list(let element):
            try expect(&index, .int, "a list's index")
            return element
        case .output:
            try expect(&index, .int, "a line's index")
            return .string
        case .dictionary(let key, let value):
            try expect(&index, key, "the key")
            return .optional(value)
        case .unknown, .record:
            _ = try typeOf(&index)
            return .unknown
        case .any:
            throw TypeError("an Any can't be indexed: cast it first, as in (value as? [Any])")
        default:
            throw TypeError("\(base) can't be indexed")
        }
    }
}
