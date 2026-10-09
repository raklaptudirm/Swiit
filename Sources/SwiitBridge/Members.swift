import Foundation

/// Range and ClosedRange are sequences, and have most of their members,
/// only when `Bound: Strideable` with a SignedInteger stride: for Swish,
/// when Bound is Int.
func strideFix(_ constraint: Constraint) -> Bool {
    constraint.kind == "conformance" && constraint.rhs == "Strideable" && constraint.lhs == "Bound"
}

/// Whether a concrete type conforms to `proto`, for constraints on them.
func conforms(_ type: SType, _ proto: String) -> Bool {
    guard case .named(let name, []) = type else { return false }
    // Swish's own Int, Double, String and Bool, which a run that isn't
    // bridging the standard library knows nothing else about.
    let comparable: Set = ["Equatable", "Hashable", "Comparable", "Encodable", "CustomStringConvertible"]
    switch name {
    case "Int", "Double", "String": return types[name]?.allConformances.contains(proto) ?? comparable.contains(proto)
    case "Bool": return types[name]?.allConformances.contains(proto) ?? comparable.subtracting(["Comparable"]).contains(proto)
    default: return types[name]?.allConformances.contains(proto) ?? false
    }
}

func available(_ symbol: Symbol) -> Bool {
    for entry in symbol.availability ?? [] {
        if entry.isUnconditionallyDeprecated == true || entry.isUnconditionallyUnavailable == true { return false }
        // Obsoleted in the language itself (domain "Swift") counts too.
        if entry.domain == "Swift" || entry.domain == "SwiftPM", entry.obsoleted != nil || entry.deprecated != nil { return false }
        guard entry.domain == nil || entry.domain == "macOS" || entry.domain == "*" else { continue }
        if entry.deprecated != nil || entry.obsoleted != nil { return false }
        if let introduced = entry.introduced, entry.domain == "macOS",
           introduced.major > 14 || introduced.major == 14 && (introduced.minor ?? 0) > 0 { return false }
    }
    return true
}

/// `init?(_ description: String)`, or `init?<S: StringProtocol>(_ text: S)`:
/// a failable initializer taking one unlabeled piece of text.
func isTextInitializer(_ symbol: Symbol) -> Bool {
    let text = (symbol.declarationFragments ?? []).map(\.spelling).joined()
    guard let declaration = try? parseDeclaration(text), declaration.isFailable, declaration.parameters.count == 1,
          declaration.parameters[0].label == nil, declaration.parameters[0].defaultText == nil else { return false }
    switch declaration.parameters[0].type {
    case .named("String", []): return true
    case .named(let generic, []): return declaration.generics[generic]?.contains("StringProtocol") ?? false
        || (symbol.swiftGenerics?.constraints ?? []).contains { $0.lhs == generic && $0.rhs == "StringProtocol" }
    default: return false
    }
}

/// `init<S: Sequence>(_ elements: S) where S.Element == Element`: an
/// initializer taking one unlabeled sequence of any kind.
func isSequenceInitializer(_ symbol: Symbol) -> Bool {
    let text = (symbol.declarationFragments ?? []).map(\.spelling).joined()
    guard let declaration = try? parseDeclaration(text), !declaration.isFailable, declaration.parameters.count == 1,
          declaration.parameters[0].label == nil, case .named(let generic, []) = declaration.parameters[0].type else { return false }
    let constraints = (symbol.swiftGenerics?.constraints ?? []) + declaration.constraints
    return (declaration.generics[generic] ?? []).contains("Sequence")
        || constraints.contains { $0.lhs == generic && $0.rhs == "Sequence" }
}

func parseType(_ text: String) throws -> SType {
    var reader = Reader(text)
    return try reader.type()
}

/// `S.Element` for a sequence parameter S: S.
func sequenceParameter(_ type: SType, _ sequences: Set<String>) -> String? {
    if case .member(.named(let parameter, []), "Element") = type, sequences.contains(parameter) { return parameter }
    return nil
}

/// The Swift for one member: its signature and glue.
func bridge(_ symbol: Symbol, of original: BridgedType, given conditions: [Constraint] = [], free: Bool = false) throws -> (key: String, shape: String, codes: [String]) {
    let text = (symbol.declarationFragments ?? []).map(\.spelling).joined()
    let declaration = try parseDeclaration(text)
    if declaration.isMutating && declaration.isStatic { throw Unsupported(reason: "mutating") }
    var owner = original
    let constraints = conditions + (symbol.swiftExtension?.constraints ?? []) + (symbol.swiftGenerics?.constraints ?? [])
        + declaration.constraints
    var ownGenerics = declaration.generics
    if let error = declaration.typedError { ownGenerics.removeValue(forKey: error) }

    // Its generic parameters that are sequences: `S: Sequence`.
    var sequenceNames = Set(ownGenerics.filter { $0.value.contains("Sequence") }.keys)
    for constraint in constraints where constraint.kind == "conformance" && constraint.rhs == "Sequence"
        && ownGenerics[constraint.lhs] != nil { sequenceNames.insert(constraint.lhs) }
    var sequences: [String: SType] = [:]
    var fixed: [String: SType] = [:]
    for constraint in constraints where strideFix(constraint) && owner.genericParameters.contains("Bound") {
        fixed["Bound"] = .named("Int", [])
    }
    for constraint in constraints where constraint.kind == "sameType" {
        let lhs = try parseType(constraint.lhs), rhs = try parseType(constraint.rhs)
        if let parameter = sequenceParameter(lhs, sequenceNames) { sequences[parameter] = rhs; continue }
        if let parameter = sequenceParameter(rhs, sequenceNames) { sequences[parameter] = lhs; continue }
        // `where Element == String`: the member is for that element only, so
        // it's bridged with Element fixed to it.
        let name = constraint.lhs.replacingOccurrences(of: "Self.", with: "")
        guard owner.genericParameters.contains(name), isLeaf(rhs) else { throw Unsupported(reason: "same-type constraint") }
        fixed[name] = rhs
    }
    for (parameter, type) in fixed {
        owner.associated[parameter] = type
        owner.fixed[parameter] = type
        owner.genericParameters.removeAll { $0 == parameter }
    }
    // A sequence whose elements aren't said: its own generic parameter.
    for parameter in sequenceNames where sequences[parameter] == nil {
        sequences[parameter] = .named("\(parameter).Element", [])
        ownGenerics["\(parameter).Element"] = []
    }
    let methodGenerics = Set(ownGenerics.keys).subtracting(sequenceNames).subtracting(owner.genericParameters)
    let allGenerics = methodGenerics.union(owner.genericParameters)
    let context = Context(owner: owner, generics: allGenerics, sequences: sequences)

    // Constraints from the member and from the extension it's in.
    var needs: [String: [String]] = ownGenerics.filter { !sequenceNames.contains($0.key) }
    for constraint in constraints where constraint.kind == "conformance" {
        if constraint.lhs == declaration.typedError || alwaysMet.contains(constraint.rhs) { continue }
        if sequenceNames.contains(constraint.lhs) && constraint.rhs == "Sequence" { continue }
        guard let resolved = resolve(try parseType(constraint.lhs), context) else {
            throw Unsupported(reason: "constraint on \(constraint.lhs)")
        }
        if case .named(let parameter, []) = resolved, allGenerics.contains(parameter) {
            needs[parameter, default: []].append(constraint.rhs)
        } else if resolved == selfType(owner) {
            guard owner.allConformances.contains(constraint.rhs) else { throw Unsupported(reason: "Self: \(constraint.rhs)") }
        } else if !conforms(resolved, constraint.rhs) {
            throw Unsupported(reason: "\(constraint.lhs): \(constraint.rhs)")
        }
    }
    var generics: [String: [String]] = [:]
    for (parameter, protocols) in needs {
        let relevant = Set(protocols).subtracting(alwaysMet)
        guard relevant.allSatisfy(valueProtocols.contains) else { throw Unsupported(reason: "constraint \(relevant.sorted())") }
        generics[parameter] = relevant.sorted()
    }
    // A parameter fixed by `where Element == String` must be that type,
    // which the checker checks as a constraint written `=String`.
    for (parameter, type) in fixed {
        if case .named(let leaf, []) = type { generics[parameter] = ["=" + leaf] }
    }
    for parameter in allGenerics where generics[parameter] == nil { generics[parameter] = [] }

    // A parameter of type ShellContext is lent by the shell: not Swish's.
    func isContext(_ parameter: Parameter) -> Bool {
        if case .named("ShellContext", []) = parameter.type { return true }
        return false
    }
    var parameters: [(Parameter, SType)] = []
    for parameter in declaration.parameters where !isContext(parameter) {
        guard let type = resolve(parameter.type, context), supported(type, generics: allGenerics, asParameter: true),
              !resultOnly.contains(where: { annotation(type).contains("\(quoted($0))") }) else {
            throw Unsupported(reason: "parameter \(parameter.type)")
        }
        parameters.append((parameter, type))
    }
    var returns: SType = .tuple([])
    var partial = false
    if declaration.kind == .initializer {
        returns = selfType(owner)
        if declaration.isFailable { returns = .optional(returns) }
    } else if var declared = declaration.returns {
        // `Partial<T>`: a result and the errors met making it, which the
        // shell reports as errors in items, then goes on with the result.
        if case .named("Partial", let inner) = declared, inner.count == 1 {
            declared = inner[0]
            partial = true
        }
        guard let type = resolve(declared, context), supported(type, generics: allGenerics, asParameter: false) else {
            throw Unsupported(reason: "result \(declared)")
        }
        if case .someSequence = type { throw Unsupported(reason: "result \(declared)") }
        returns = type
    }
    // A method-level generic parameter that isn't in a parameter can't be
    // inferred by the glue.
    for parameter in methodGenerics {
        let mentioned = parameters.contains { annotation($0.1).contains("\"\(parameter)\"") }
        if !mentioned { throw Unsupported(reason: "uninferrable generic \(parameter)") }
    }

    let shape = "\(declaration.kind) \(declaration.isStatic) \(declaration.name)(" + parameters.map { "\($0.0.label ?? "_"):" }.joined() + ")"
    let key = "\(declaration.kind) \(declaration.isStatic) \(declaration.name)(" + parameters.map { "\($0.0.label ?? "_"):\(annotation($0.1))" }.joined(separator: ",") + ")"

    // The signature.
    let parameterCode = parameters.map { parameter, type in
        // In the order `Parameter` declares them.
        // `@Rest` on an array: Swish's variadic parameter, of the element's type.
        var swishType = type
        if parameter.isRest, case .array(let element) = type { swishType = element }
        var fields = ["label: \(parameter.label.map(quoted) ?? "nil")", "name: \(quoted(parameter.name))", "type: \(annotation(swishType))"]
        if parameter.isRest { fields.append("variadic: true") }
        let literal = parameter.defaultText.flatMap(literalDefault)
        if let literal { fields.append("defaultValue: \(literal)") }
        if parameter.isInput { fields.append("isInput: true") }
        if let flag = parameter.shortFlag { fields.append("shortFlag: \(quoted(String(flag)))") }
        if let text = parameter.defaultText, literal == nil, !parameter.isRest { fields.append("externalDefault: \(quoted(text))") }
        return "Parameter(\(fields.joined(separator: ", ")))"
    }
    // The glue.
    let argumentList = declaration.parameters.map { parameter -> String in
        if isContext(parameter) { return (parameter.label.map { "\($0): " } ?? "") + "shell.context" }
        let type = parameters.first { $0.0.name == parameter.name }!.1
        let value = "args[\(quoted(parameter.name))]"
        var expr = fromSwish("\(value)!", type)
        if let text = parameter.defaultText, literalDefault(text) == nil {
            expr = "(\(value) == nil ? \(text) : \(fromSwish("\(value)!", type)))"
        }
        return (parameter.label.map { "\($0): " } ?? "") + expr
    }
    let arguments = argumentList.joined(separator: ", ")
    let receiverType = selfType(owner)
    let swiftType = spelling(receiverType)
    let target: String
    switch declaration.kind {
    case .initializer: target = "\(swiftType)(\(arguments))"
    case .method where declaration.isOperator:
        // Written as Swift writes it: `-(a)`, `(a) + (b)`.
        target = argumentList.count == 1 ? "\(declaration.name)(\(argumentList[0]))"
            : "(\(argumentList[0])) \(declaration.name) (\(argumentList[1]))"
    case .method:
        // A free function is the module's own: qualified, so a standard
        // library function of the same name (readLine) isn't ambiguous.
        target = (free ? graph.module.name : declaration.isStatic ? swiftType : "receiver") + ".\(swiftName(declaration.name))(\(arguments))"
    case .property: target = (declaration.isStatic ? swiftType : "receiver") + ".\(swiftName(declaration.name))"
    }
    let tryPrefix = declaration.throwing || declaration.rethrowing ? "try " : ""
    var body = ""
    if !declaration.isStatic && declaration.kind != .initializer && !free {
        let binding = declaration.isMutating ? "var" : "let"
        body += "\(binding) receiver: \(swiftType) = \(fromSwish("args[\"self\"]!", receiverType))\n                "
    }
    let isVoid = if case .tuple(let elements) = returns, elements.isEmpty { true } else { false }
    // A result that's an array is typed, so Swift picks the overload the
    // signature came from: `Sequence.dropLast() -> [Element]`, not the
    // Slice a Set's own Collection conformance would give.
    let resultType: String
    if case .array = returns { resultType = ": \(spelling(returns))" } else { resultType = "" }
    if declaration.isMutating {
        // The result, and the receiver as the call left it, for the shell to
        // put back where it came from (see `Shell.runBridged`).
        body += isVoid ? "\(tryPrefix)\(target)\n                " : "let result\(resultType) = \(tryPrefix)\(target)\n                "
        body += "return .list([\(isVoid ? ".nothing" : toSwish("result", returns)), \(toSwish("receiver", receiverType))])"
    } else if isVoid {
        body += "\(tryPrefix)\(target)\n                return .nothing"
    } else if partial {
        body += "let partial = \(tryPrefix)\(target)\n                for error in partial.errors { shell.reportItemError(\"\\(\(quoted(declaration.name))): \\(error)\") }\n"
        body += "                let result\(resultType) = partial.value\n                return \(toSwish("result", returns))"
    } else {
        body += "let result\(resultType) = \(tryPrefix)\(target)\n                return \(toSwish("result", returns))"
    }
    let kind = declaration.kind == .initializer ? ".initializer" : declaration.kind == .property ? ".property" : ".method"
    // `var extension: String? { get set }`: a setter too, which changes a
    // copy of the receiver and gives it back, as a mutating method does.
    var setter: String?
    if declaration.kind == .property, !declaration.isStatic, text.contains("set }") {
        setter = """
                BridgedMember(
                    kind: .setter, name: \(quoted(declaration.name)), isStatic: false,
                    parameters: [Parameter(label: nil, name: "newValue", type: \(annotation(returns)))],
                    returns: .void, generics: [:],
                    isThrowing: false, isRethrowing: false, isMutating: true,
                    discardableResult: false, summary: "",
                    body: .native { shell, args in
                        _ = shell
                        var receiver: \(swiftType) = \(fromSwish("args[\"self\"]!", receiverType))
                        receiver.\(swiftName(declaration.name)) = \(fromSwish("args[\"newValue\"]!", returns))
                        return .list([.nothing, \(toSwish("receiver", receiverType))])
                    }
                )
"""
    }
    // A function's flags are documented in `help`; a member's are not shown.
    let docs = free ? symbol.parameterDocs : [:]
    let parameterDocs = docs.isEmpty ? "" : ",\n                    parameterDocs: [" + docs.sorted { $0.key < $1.key }.map { "\(quoted($0.key)): \(quoted($0.value))" }.joined(separator: ", ") + "]"
    let genericsCode = generics.isEmpty ? "[:]" : "[" + generics.sorted { $0.key < $1.key }.map { "\(quoted($0.key)): [\($0.value.map(quoted).joined(separator: ", "))]" }.joined(separator: ", ") + "]"
    // A key path reads fields as the shell reads them, for as long as the call.
    if parameters.contains(where: { annotation($0.1).hasPrefix(".keyPath") }) {
        body = "return try withFieldReader(shell) { () throws -> Value in\n\(body)\n                }"
    }
    let member = """
                BridgedMember(
                    kind: \(kind), name: \(quoted(declaration.name)), isStatic: \(declaration.isStatic),
                    parameters: [\(parameterCode.joined(separator: ", "))],
                    returns: \(annotation(returns)), generics: \(genericsCode),
                    isThrowing: \(declaration.throwing), isRethrowing: \(declaration.rethrowing), isMutating: \(declaration.isMutating),
                    discardableResult: \(text.contains("@discardableResult")), summary: \(quoted(symbol.summary)),
                    body: .native { shell, args in
                        _ = shell
                        \(body)
                    }\(parameterDocs)
                )
"""
    return (key, shape, [member] + (setter.map { [$0] } ?? []))
}
