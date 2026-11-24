import Foundation

extension TypeChecker {
    // MARK: Sequence methods

    /// `xs.filter { … }` and the rest: the prelude's `extension Sequence`,
    /// with `Element` the receiver's items' type.
    func sequenceMethodType(
        _ name: String,
        on base: TypeExpression,
        _ callee: inout Expr,
        _ arguments: inout [Argument]
    ) throws -> TypeExpression? {
        guard let methods = interpreter.sequenceMethods[name], let element = sequenceElement(base)
        else { return nil }
        let candidates = sequenceSignatures(methods)
        guard
            let chosen = try resolve(
                candidates,
                &arguments,
                name: name,
                bindings: ["Element": element]
            )
        else {
            return commonReturn(candidates)
        }
        if candidates.count > 1 { callee = .chosen(callee, overload: chosen.index) }
        if chosen.isThrowing { try throwingSite("'\(name)'") }
        return chosen.returns
    }

    /// A sequence method's signature as it's called: without the `@input`
    /// the sequence comes in by.
    func sequenceSignatures(_ methods: OverloadSet) -> [Signature] {
        methods.candidates.enumerated()
            .map { index, method in
                var signature = signature(method)
                signature.parameters.removeAll(where: { $0.name == "self" })
                signature.index = index
                return signature
            }
    }

    /// The type of a sequence's items, for its methods; nil if it isn't one.
    func sequenceElement(_ type: TypeExpression) -> TypeExpression? {
        if let name = type.plainName,
            let element = interpreter.bridged[name]?.checkedAssociatedTypes["Element"]
        {
            return element
        }
        if type.genericParts != nil { return bridgedElement(type) }
        if let element = type.arrayElement { return element }
        return type == .unknown ? .unknown : nil
    }
}

extension TypeChecker {
    // MARK: Swift's members

    /// The Swift type a Swiit type is, with its generic parameters bound:
    /// `[Int]` is Array with Element Int.
    func bridged(_ type: TypeExpression) -> (ImplementedType, [String: TypeExpression])? {
        Bridge.type(of: type, in: interpreter.bridged)
    }

    /// Whether a bridged type, with its generic parameters bound, conforms
    /// to `proto`: a ClosedRange<Int> is a Sequence, a ClosedRange<Double>
    /// isn't.
    func bridgedConforms(
        _ bridgedType: ImplementedType,
        _ bindings: [String: TypeExpression],
        to proto: String
    ) -> Bool {
        guard let needs = bridgedType.conformance(named: proto) else {
            return proto == "CustomStringConvertible"
        }
        return needs.allSatisfy { parameter in
            parameter.constraints.allSatisfy {
                satisfies(bindings[parameter.name] ?? .unknown, $0)
            }
        }
    }

    /// The Element of a bridged Swift type that's a Sequence: Int for a
    /// ClosedRange<Int>, Character for a Substring; nil if it isn't one.
    func bridgedElement(_ type: TypeExpression) -> TypeExpression? {
        guard let (bridgedType, bindings) = bridged(type),
            bridgedConforms(bridgedType, bindings, to: "Sequence")
        else {
            return nil
        }
        guard
            let element = bridgedType.checkedAssociatedTypes["Element"]
                ?? (bridgedType.genericParameterNames.contains("Element")
                    ? .parameter("Element") : nil)
        else { return nil }
        return substitute(element, bindings)
    }

    /// What a Swift parameter taking any sequence gets from a value of
    /// `type`: a String's Characters, a dictionary's (key, value) pairs.
    func anySequenceElement(_ type: TypeExpression) -> TypeExpression? {
        type == .unknown ? .unknown : bridgedElement(type) ?? (try? elementType(of: type)) ?? nil
    }

    /// A bridged property, `"abc".count` or `Int.max`, as a lookup the
    /// interpreter runs; nil if the type has no such property.
    func bridgedProperty(
        _ typeName: String,
        receiver: Expr?,
        bindings: [String: TypeExpression],
        _ name: String
    ) throws -> (TypeExpression, Expr)? {
        guard let bridgedType = interpreter.bridged[typeName],
            let index = bridgedType.lowered.firstIndex(where: {
                $0.kind == .property && $0.name == name && $0.isStatic == (receiver == nil)
            })
        else { return nil }
        let member = bridgedType.lowered[index]
        let type = substitute(member.returns, bindings)
        try bridgedEffects(member, bindings: bindings, throwing: member.isThrowing, "'\(name)'")
        return (type, .bridged(type: typeName, member: index, receiver: receiver, arguments: []))
    }

    // swiftlint:disable function_parameter_count - it threads one state through; splitting it is item 25 of Docs/agenda.md
    /// A bridged method or initializer called with `arguments`: the overload
    /// is chosen here, and the call written as the member it is.
    func bridgedCall(
        _ typeName: String,
        kind: BridgedMember.Kind,
        isStatic: Bool,
        receiver: Expr?,
        bindings: [String: TypeExpression],
        name: String,
        _ arguments: inout [Argument]
    ) throws -> (TypeExpression, Expr) {
        guard let bridgedType = interpreter.bridged[typeName] else {
            throw TypeError("no Swift type named \(typeName)")
        }
        let candidates = bridgedType.lowered.enumerated()
            .filter {
                $0.element.kind == kind && $0.element.name == name
                    && $0.element.isStatic == isStatic
            }
            .map { index, member in
                Signature(
                    name: kind == .initializer ? typeName : name,
                    parameters: member.parameters,
                    returns: member.returns,
                    isThrowing: member.isThrowing,
                    isRethrowing: member.isRethrowing,
                    effect: member.effect,
                    index: index,
                    generics: member.generics
                )
            }
        guard !candidates.isEmpty else {
            throw TypeError(
                kind == .initializer
                    ? "\(typeName) can't be made this way from Swiit yet"
                    : "\(typeName) has no member '\(name)'"
            )
        }
        var chosen = try resolve(
            candidates,
            &arguments,
            name: candidates[0].name,
            bindings: bindings
        )
        if chosen == nil, candidates.count == 1 { chosen = candidates[0] }
        guard let chosen else {
            throw TypeError(
                "\(candidates[0].name): which overload isn't clear until the arguments' types are known"
            )
        }
        try bridgedEffects(
            bridgedType.lowered[chosen.index],
            bindings: bindings,
            throwing: chosen.isThrowing,
            "'\(name)'"
        )
        if bridgedType.lowered[chosen.index].isMutating {
            // `xs.append(1)` changes xs, which must be a `var`.
            guard let receiver else {
                throw TypeError("\(typeName).\(name) is mutating: call it on a variable")
            }
            try checkMutable(receiver, method: name)
        }
        return (
            chosen.returns,
            .bridged(type: typeName, member: chosen.index, receiver: receiver, arguments: arguments)
        )
    }
    // swiftlint:enable function_parameter_count

    /// A bridged member used here: it throws, as it says or by its typed
    /// `throws(Failure)` unless Failure is bound to `Never`; and it waits, if
    /// it's `async`.
    func bridgedEffects(
        _ member: BridgedMember,
        bindings: [String: TypeExpression],
        throwing: Bool,
        _ what: String
    ) throws {
        let typed = member.typedThrows.map { bindings[$0] != .named("Never") } ?? false
        if throwing || typed { try throwingSite(what) }
        try effectSite(member.effect, what)
    }

    /// A string literal where a type with literal initializers is wanted, made as Swift makes one:
    /// the text is a scalar, a character or a string, and the type's own initializer for the most
    /// specific of those kinds it has takes it (`init(unicodeScalarLiteral:)`,
    /// `init(extendedGraphemeClusterLiteral:)` or `init(stringLiteral:)`). Nil if `expected` is not
    /// a type that has any; an error if it has some and none takes this text.
    func textLiteral(_ text: String, as expected: TypeExpression) throws -> (String, Value)? {
        if let wrapped = expected.optionalWrapped { return try textLiteral(text, as: wrapped) }
        guard expected.isNominal, !expected.isPrimitive, let name = expected.plainName else {
            return nil
        }
        guard let type = interpreter.bridged[name] else { return nil }
        let initializers = type.lowered.enumerated()
            .filter {
                $0.element.kind == .initializer && $0.element.parameters.count == 1
                    && $0.element.parameters[0].label.map(TextLiteralKind.init(label:)) != nil
            }
        guard !initializers.isEmpty else { return nil }
        for kind in TextLiteralKind.applicable(to: text) {
            for (index, member) in initializers
            where member.parameters[0].label == kind.label {
                guard let argument = kind.argument(text, for: member.parameters[0].type)
                else { continue }
                do {
                    let made = try interpreter.runBridged(
                        name,
                        index,
                        receiver: nil,
                        [Argument(label: kind.label, value: .literal(argument))]
                    )
                    return (name, made)
                } catch {
                    throw TypeError("\(Value.quoted(text)) isn't a \(name) literal: \(error)")
                }
            }
        }
        throw TypeError("\(Value.quoted(text)) isn't a \(name) literal")
    }

    /// Whether `expr` is a name that isn't a value: a type, `env`.
    static func namesSomething(_ expr: Expr, in checker: TypeChecker) -> Bool {
        guard case .variable(let name) = expr else { return false }
        switch checker.lookup(name) {
        case .enumType?, .swiftType?, .structType?: return true
        default: return false
        }
    }
}

extension TypeChecker {
    // MARK: Members

    func memberType(_ baseExpr: inout Expr, _ name: String) throws -> TypeExpression {
        if case .variable(let typeName) = baseExpr, let symbol = lookup(typeName) {
            switch symbol {
            case .enumType, .structType:
                guard let description = describe(named: typeName) else { break }
                switch description.staticMember(name) {
                case .property(let property)?: return property.type
                case .methods(let methods, _)?:
                    return methods.count == 1 ? functionType(methods[0]) : .callable
                case .enumCase?, nil: break
                }
                guard description.kind == .enumeration else {
                    throw TypeError("\(description.name) has no static member '\(name)'")
                }
                if name == "allCases" {
                    throw TypeError(
                        "\(description.name) has no allCases: some cases have associated values"
                    )
                }
                var none: [Argument]?
                return try caseType(name, &none, expected: .named(description.name))
            default:
                break
            }
        }
        return try memberType(of: try typeOf(&baseExpr), name)
    }

    /// Whether the host described the type `base` with a member `name` (`describeHostType`).
    private func describesMember(_ name: String, of base: TypeExpression) -> Bool {
        guard let typeName = base.plainName, isProtocolType(typeName) else { return false }
        return describe(named: typeName)?.instanceMember(name) != nil
    }

    func memberType(of written: TypeExpression, _ name: String) throws -> TypeExpression {
        let base = erased(written)
        // What the type declares, or an extension (or a protocol's default) adds.
        let description = describe(base)
        let bindings = elementBindings(for: base)
        switch description?.instanceMember(name) {
        case .property(let property)?: return substitute(property.type, bindings)
        case .methods(let methods, _)?:
            return methods.count == 1 ? substitute(functionType(methods[0]), bindings) : .callable
        case .enumCase?, nil: break
        }
        // Every value has its textual form, as interpolation shows it; a
        // struct's own property of that name comes first.
        if name == "description" || name == "debugDescription" { return .string }
        // Swift's own properties, as in `\.count`.
        if let (bridgedType, bindings) = bridged(base),
            let property = bridgedType.lowered.first(where: {
                $0.kind == .property && !$0.isStatic && $0.name == name
            })
        {
            return substitute(property.returns, bindings)
        }
        if base == .unknown || base == .record { return .unknown }
        if case .metatype = base { return .unknown }
        if base == .any {
            throw TypeError("an Any has no members: cast it first, as in (value as? T)?.\(name)")
        }
        if base.optionalWrapped != nil {
            throw TypeError(
                "\(base) might be nil: unwrap it (if let, ??, ?. or !) before using .\(name)"
            )
        }
        if base.isNominal, !base.isPrimitive, let typeName = base.plainName {
            switch description?.kind {
            case .protocol?, .structure?, .class?, .actor?:
                throw TypeError("\(typeName) has no member '\(name)'")
            case .enumeration?:
                throw TypeError(
                    name == "rawValue"
                        ? "\(typeName) has no raw values" : "\(typeName) has no member '\(name)'"
                )
            default:
                break
            }
            if interpreter.bridged[typeName] != nil {
                throw TypeError("\(typeName) has no member '\(name)'")
            }
            return .unknown
        }
        // A host type's instance with what it holds (`Job<Int>`): the members the host described.
        if let (typeName, _) = base.genericParts, isProtocolType(typeName) {
            return try memberType(of: .named(typeName), name)
        }
        if case .tuple(let tuple) = base, !tuple.elements.isEmpty {
            guard let element = tupleElement(name, of: tuple.elements) else {
                throw TypeError("\(base) has no element '\(name)'")
            }
            return element
        }
        throw TypeError("\(base) has no member '\(name)'")
    }

    /// `x.name` on a `@dynamicMemberLookup` type that has no member of that name: the arguments of
    /// `x[dynamicMember: "name"]`, and what it gives.
    func dynamicMember(
        of base: TypeExpression,
        _ name: String
    ) throws -> (arguments: [Argument], type: TypeExpression)? {
        guard let typeName = (erased(base).plainName), let info = structInfo(named: typeName),
            info.isDynamicMemberLookup, describe(erased(base))?.instanceMember(name) == nil,
            name != "description", name != "debugDescription"
        else {
            return nil
        }
        var arguments = [Argument(label: "dynamicMember", value: .literal(.string(name)))]
        return (arguments, try structSubscript(info, &arguments).type)
    }

    func tupleElement(
        _ name: String,
        of elements: [TypeExpression.Tuple.Element]
    ) -> TypeExpression? {
        if let position = Int(name), elements.indices.contains(position) {
            return elements[position].type
        }
        return elements.first { $0.label == name }?.type
    }

    func caseType(
        _ name: String,
        _ arguments: inout [Argument]?,
        expected: TypeExpression?
    ) throws -> TypeExpression {
        var requested = expected
        if let wrapped = requested?.optionalWrapped { requested = wrapped }
        guard let found = requested, found != .unknown, found != .any else {
            if requested == nil {
                throw TypeError(
                    ".\(name) needs a type here; write the enum's name too, as in Kind.\(name)"
                )
            }
            for index in (arguments ?? []).indices {
                _ = try typeOf(&arguments![index].value, expecting: .unknown)
            }
            return .unknown
        }
        var target = found
        // A generic enum's type arguments say what its cases hold: `Result<Int, E>`.
        var bindings: [String: TypeExpression] = [:]
        var result: TypeExpression? = target
        if let (genericName, arguments) = target.genericParts,
            let info = enumInfo(named: genericName),
            info.typeParameters.count == arguments.count
        {
            bindings = Dictionary(uniqueKeysWithValues: zip(info.typeParameters, arguments))
            result = .named(genericName)
            target = .named(genericName)
        }
        // What isn't known (an erased type parameter) leaves the case to its payload.
        if case .parameter = target {
            for index in (arguments ?? []).indices {
                _ = try typeOf(&arguments![index].value, expecting: .unknown)
            }
            return .unknown
        }
        guard let enumName = target.plainName, let info = enumInfo(named: enumName) else {
            throw TypeError(".\(name) is a case, but a \(target) is wanted here")
        }
        guard let rawPayload = info.payload(of: name) else {
            throw TypeError("\(enumName) has no case '\(name)'")
        }
        let payload = rawPayload.map { value -> AssociatedValue in
            var copy = value
            copy.type = bindings.isEmpty ? value.type : substitute(value.type, bindings)
            return copy
        }
        guard arguments != nil else {
            guard payload.isEmpty else {
                let labels = payload.map { ($0.label ?? "_") + ":" }.joined()
                throw TypeError(
                    "\(enumName).\(name) needs its associated values: \(enumName).\(name)(\(labels))"
                )
            }
            return result ?? .named(enumName)
        }
        guard !payload.isEmpty else {
            throw TypeError("\(enumName).\(name) has no associated values")
        }
        guard arguments!.count == payload.count else {
            throw TypeError(
                "\(enumName).\(name) has \(payload.count) associated values, not \(arguments!.count)"
            )
        }
        for index in arguments!.indices {
            guard arguments![index].label == payload[index].label else {
                let wanted = payload[index].label.map { "'\($0):'" } ?? "no label"
                throw TypeError("\(enumName).\(name): value #\(index + 1) needs \(wanted)")
            }
            try expect(
                &arguments![index].value,
                payload[index].type,
                "\(enumName).\(name): value #\(index + 1)"
            )
        }
        return result ?? .named(enumName)
    }

    /// What a struct's `subscript` gives for `arguments`, and whether it can be set.
    func structSubscript(
        _ info: TypeProfile,
        _ arguments: inout [Argument]
    ) throws -> (type: TypeExpression, settable: Bool) {
        guard !info.subscripts.isEmpty else {
            throw TypeError("\(info.name) can't be indexed: it has no subscript")
        }
        guard
            let chosen = try resolve(info.subscripts, &arguments, name: "\(info.name)'s subscript")
        else {
            return (commonReturn(info.subscripts), info.subscriptSettable.contains(true))
        }
        return (chosen.returns, info.subscriptSettable[chosen.index])
    }

    func indexType(_ baseExpr: inout Expr, _ index: inout Expr) throws -> TypeExpression {
        return try indexType(of: try typeOf(&baseExpr), &index)
    }

    /// Indexing a value of type `base` with `index`.
    func indexType(of base: TypeExpression, _ index: inout Expr) throws -> TypeExpression {
        if let structName = base.plainName, let info = structInfo(named: structName),
            !info.subscripts.isEmpty
        {
            var arguments = [Argument(value: index)]
            let result = try structSubscript(info, &arguments).type
            index = arguments[0].value
            return result
        }
        if let element = base.arrayElement {
            // `xs[1...3]` is a slice.
            let written = try typeOf(&index)
            if let (name, arguments) = written.genericParts,
                name == "ClosedRange" || name == "Range",
                arguments == [.int]
            {
                return .named("ArraySlice", [element])
            }
            try expect(&index, .int, "a list's index")
            return element
        }
        if base == .string {
            // A String is indexed by its own positions, not by Int, as in Swift.
            let written = try typeOf(&index)
            if written == .named("String.Index") { return .named("Character") }
            if let (name, arguments) = written.genericParts,
                name == "ClosedRange" || name == "Range",
                arguments == [.named("String.Index")]
            {
                return .named("Substring")
            }
            if written == .unknown { return .unknown }
            throw TypeError(
                "a String is indexed by String.Index, not \(written): write s.index(s.startIndex, offsetBy: n)"
            )
        }
        if base.isNominal, !base.isPrimitive, let name = base.plainName,
            interpreter.bridged[name]?.conformance(named: "Sequence") != nil,
            let element = interpreter.bridged[name]?.checkedAssociatedTypes["Element"]
        {
            // A Swift sequence Swiit holds is indexed by position (a host type's text, by line).
            try expect(&index, .int, "an element's index")
            return element
        }
        if let (key, value) = base.dictionaryTypes {
            try expect(&index, key, "the key")
            return .optional(value)
        }
        if base == .unknown || base == .record {
            _ = try typeOf(&index)
            return .unknown
        }
        if base == .any {
            throw TypeError("an Any can't be indexed: cast it first, as in (value as? [Any])")
        }
        throw TypeError("\(base) can't be indexed")
    }
}

extension TypeChecker {
    /// What `value[…]` gives when an extension adds a subscript to a type that is not a struct or
    /// a class (an `Array`, a `String`, a type of Swift's) and one of them takes the arguments;
    /// nil to read it as the type itself does.
    func extensionSubscript(
        on base: TypeExpression,
        _ arguments: inout [Argument]
    ) throws -> TypeExpression? {
        if let name = base.plainName, structInfo(named: name) != nil { return nil }
        guard let extended = describe(erased(base))?.extended, !extended.subscripts.isEmpty
        else { return nil }
        var attempt = arguments
        guard let chosen = try? resolve(extended.subscripts, &attempt, name: "subscript")
        else { return nil }
        arguments = attempt
        return substitute(chosen.returns, elementBindings(for: base))
    }
}
