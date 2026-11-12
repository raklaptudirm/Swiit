import Foundation

/// Range and ClosedRange are sequences, and have most of their members,
/// only when `Bound: Strideable` with a SignedInteger stride: for Swiit,
/// when Bound is Int.
func strideFix(_ constraint: Constraint) -> Bool {
    constraint.kind == "conformance" && constraint.rhs == "Strideable" && constraint.lhs == "Bound"
}

/// Whether a concrete type conforms to `proto`, for constraints on them.
func conforms(_ type: SType, _ proto: String) -> Bool {
    guard case .named(let name, []) = type else { return false }
    // Swiit's own Int, Double, String and Bool, which a run that isn't
    // bridging the standard library knows nothing else about.
    let comparable: Set = [
        "Equatable", "Hashable", "Comparable", "Encodable", "CustomStringConvertible",
    ]
    switch name {
    case "Int", "Double", "String":
        return types[name]?.allConformances.contains(proto) ?? comparable.contains(proto)
    case "Bool":
        return types[name]?.allConformances.contains(proto)
            ?? comparable.subtracting(["Comparable"]).contains(proto)
    default: return types[name]?.allConformances.contains(proto) ?? false
    }
}

func available(_ symbol: Symbol) -> Bool {
    for entry in symbol.availability ?? [] {
        if entry.isUnconditionallyDeprecated == true || entry.isUnconditionallyUnavailable == true {
            return false
        }
        // Obsoleted in the language itself (domain "Swift") counts too.
        if entry.domain == "Swift" || entry.domain == "SwiftPM",
            entry.obsoleted != nil || entry.deprecated != nil
        {
            return false
        }
        guard entry.domain == nil || entry.domain == "macOS" || entry.domain == "*" else {
            continue
        }
        if entry.deprecated != nil || entry.obsoleted != nil { return false }
        if let introduced = entry.introduced, entry.domain == "macOS",
            introduced.major > 14 || introduced.major == 14 && (introduced.minor ?? 0) > 0
        {
            return false
        }
    }
    return true
}

/// `init?(_ description: String)`, or `init?<S: StringProtocol>(_ text: S)`:
/// a failable initializer taking one unlabeled piece of text.
func isTextInitializer(_ symbol: Symbol) -> Bool {
    let text = (symbol.declarationFragments ?? []).map(\.spelling).joined()
    guard let declaration = try? parseDeclaration(text), declaration.isFailable,
        declaration.parameters.count == 1,
        declaration.parameters[0].label == nil, declaration.parameters[0].defaultText == nil
    else { return false }
    switch declaration.parameters[0].type {
    case .named("String", []): return true
    case .named(let generic, []):
        return declaration.generics[generic]?.contains("StringProtocol") ?? false
            || (symbol.swiftGenerics?.constraints ?? [])
                .contains { $0.lhs == generic && $0.rhs == "StringProtocol" }
    default: return false
    }
}

/// `init<S: Sequence>(_ elements: S) where S.Element == Element`: an
/// initializer taking one unlabeled sequence of any kind.
func isSequenceInitializer(_ symbol: Symbol) -> Bool {
    let text = (symbol.declarationFragments ?? []).map(\.spelling).joined()
    guard let declaration = try? parseDeclaration(text), !declaration.isFailable,
        declaration.parameters.count == 1,
        declaration.parameters[0].label == nil,
        case .named(let generic, []) = declaration.parameters[0].type
    else { return false }
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
    if case .member(.named(let parameter, []), "Element") = type, sequences.contains(parameter) {
        return parameter
    }
    return nil
}

/// The Swift for one member: the key that tells overloads apart, the shape of its signature (to
/// tell a default from one another module adds), and the source of its declaration.
struct BridgedMember {
    var key: String
    var shape: String
    var code: String
}

// swiftlint:disable cyclomatic_complexity function_body_length - one branch for each case; a long walk over every case; splitting it is item 17 of Docs/agenda.md
/// The Swift for one member: its signature and glue. A top-level function (`isFree`) has no owner
/// type: it is called by its name alone.
func bridge(
    _ symbol: Symbol,
    of original: BridgedType,
    given conditions: [Constraint] = [],
    isFree: Bool = false
) throws -> BridgedMember {
    let text = (symbol.declarationFragments ?? []).map(\.spelling).joined()
    var declaration = try parseDeclaration(text)
    if isFree { declaration.isStatic = true }
    if declaration.isMutating && declaration.isStatic { throw Unsupported(reason: "mutating") }
    var owner = original
    let constraints =
        conditions + (symbol.swiftExtension?.constraints ?? [])
        + (symbol.swiftGenerics?.constraints ?? [])
        + declaration.constraints
    var ownGenerics = declaration.generics
    if let error = declaration.typedError { ownGenerics.removeValue(forKey: error) }

    // Its generic parameters that are sequences: `S: Sequence`.
    var sequenceNames = Set(ownGenerics.filter { $0.value.contains("Sequence") }.keys)
    for constraint in constraints
    where constraint.kind == "conformance" && constraint.rhs == "Sequence"
        && ownGenerics[constraint.lhs] != nil
    { sequenceNames.insert(constraint.lhs) }
    var sequences: [String: SType] = [:]
    var fixed: [String: SType] = [:]
    for constraint in constraints
    where strideFix(constraint) && owner.genericParameters.contains("Bound") {
        fixed["Bound"] = .named("Int", [])
    }
    for constraint in constraints where constraint.kind == "sameType" {
        let lhs = try parseType(constraint.lhs), rhs = try parseType(constraint.rhs)
        if let parameter = sequenceParameter(lhs, sequenceNames) {
            sequences[parameter] = rhs; continue
        }
        if let parameter = sequenceParameter(rhs, sequenceNames) {
            sequences[parameter] = lhs; continue
        }
        // `where Element == String`: the member is for that element only, so
        // it's bridged with Element fixed to it.
        let name = constraint.lhs.replacingOccurrences(of: "Self.", with: "")
        guard owner.genericParameters.contains(name), isLeaf(rhs) else {
            throw Unsupported(reason: "same-type constraint")
        }
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
    let methodGenerics = Set(ownGenerics.keys).subtracting(sequenceNames)
        .subtracting(owner.genericParameters)
    let allGenerics = methodGenerics.union(owner.genericParameters)
    let context = Context(owner: owner, generics: allGenerics, sequences: sequences)

    // Constraints from the member and from the extension it's in.
    var needs: [String: [String]] = ownGenerics.filter { !sequenceNames.contains($0.key) }
    for constraint in constraints where constraint.kind == "conformance" {
        if constraint.lhs == declaration.typedError || alwaysMet.contains(constraint.rhs) {
            continue
        }
        if sequenceNames.contains(constraint.lhs) && constraint.rhs == "Sequence" { continue }
        guard let resolved = resolve(try parseType(constraint.lhs), context) else {
            throw Unsupported(reason: "constraint on \(constraint.lhs)")
        }
        if case .named(let parameter, []) = resolved, allGenerics.contains(parameter) {
            needs[parameter, default: []].append(constraint.rhs)
        } else if resolved == selfType(owner) {
            guard owner.allConformances.contains(constraint.rhs) else {
                throw Unsupported(reason: "Self: \(constraint.rhs)")
            }
        } else if !conforms(resolved, constraint.rhs) {
            throw Unsupported(reason: "\(constraint.lhs): \(constraint.rhs)")
        }
    }
    var generics: [String: [String]] = [:]
    for (parameter, protocols) in needs {
        let relevant = Set(protocols).subtracting(alwaysMet)
        guard relevant.allSatisfy(valueProtocols.contains) else {
            throw Unsupported(reason: "constraint \(relevant.sorted())")
        }
        generics[parameter] = relevant.sorted()
    }
    // A parameter fixed by `where Element == String` must be that type,
    // which the checker checks as a constraint written `=String`.
    for (parameter, type) in fixed {
        if case .named(let leaf, []) = type { generics[parameter] = ["=" + leaf] }
    }
    for parameter in allGenerics where generics[parameter] == nil { generics[parameter] = [] }

    // Swift cannot pass an array on as variadic arguments, so a variadic member is called through
    // the overload that takes the array, which its author writes beside it.
    if declaration.parameters.contains(where: \.isVariadic), !hasArrayOverload(symbol, declaration)
    {
        throw Unsupported(reason: "variadic")
    }
    var parameters: [(Parameter, SType)] = []
    for parameter in declaration.parameters {
        guard let type = resolve(parameter.type, context),
            supported(type, generics: allGenerics, asParameter: true)
        else {
            throw Unsupported(reason: "parameter \(parameter.type)")
        }
        parameters.append((parameter, type))
    }
    var returns: SType = .tuple([])
    if declaration.kind == .initializer {
        returns = selfType(owner)
        if declaration.isFailable { returns = .optional(returns) }
    } else if let declared = declaration.returns {
        guard let type = resolve(declared, context),
            supported(type, generics: allGenerics, asParameter: false)
        else {
            throw Unsupported(reason: "result \(declared)")
        }
        if case .someSequence = type { throw Unsupported(reason: "result \(declared)") }
        returns = type
    }
    // A method-level generic parameter that isn't in a parameter can't be
    // inferred by the glue.
    for parameter in methodGenerics {
        let mentioned = parameters.contains { scriptType($0.1).contains("\"\(parameter)\"") }
        if !mentioned { throw Unsupported(reason: "uninferrable generic \(parameter)") }
    }

    let shape =
        "\(declaration.kind) \(declaration.isStatic) \(declaration.name)("
        + parameters.map { "\($0.0.label ?? "_"):" }.joined() + ")"
    let key =
        "\(declaration.kind) \(declaration.isStatic) \(declaration.name)("
        + parameters.map {
            "\($0.0.label ?? "_"):\(scriptType($0.1))\($0.0.isVariadic ? "..." : "")"
        }
        .joined(separator: ",") + ")"

    // The signature.
    let parameterCode = try parameters.map { try describedParameter($0, $1) }

    // The glue.
    let conversions = declaration.parameters.enumerated()
        .map { index, parameter -> String in
            let type = parameters.first { $0.0.name == parameter.name }!.1
            let value = "arguments[\(index)]"
            var expr = fromValue(value, parameter.isVariadic ? .array(type) : type)
            if let text = parameter.defaultText, literalDefault(text) == nil {
                expr = "(\(value) == .nothing ? \(text) : \(fromValue(value, type)))"
            }
            return expr
        }
    // A member that would trap on some arguments checks them first, from their own names.
    let checked = applicablePreconditions(
        of: owner.name,
        declaration,
        parameterTypes: parameters.map { spelling($0.1) }
    )
    let conditions = checked.filter { $0.when != nil }
    if checked.isEmpty && looksAsIfItCanTrap(declaration) {
        uncheckedMembers.append("\(owner.name)\t\(memberKey(declaration))")
    }
    let argumentList = declaration.parameters.enumerated()
        .map { index, parameter -> String in
            let expr =
                conditions.isEmpty ? conversions[index] : conditionVariable(parameter, at: index)
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
        target =
            argumentList.count == 1
            ? "\(declaration.name)(\(argumentList[0]))"
            : "(\(argumentList[0])) \(declaration.name) (\(argumentList[1]))"
    case .method where isFree: target = "\(swiftName(declaration.name))(\(arguments))"
    case .method:
        target =
            (declaration.isStatic ? swiftType : "receiver")
            + ".\(swiftName(declaration.name))(\(arguments))"
    case .property:
        target = (declaration.isStatic ? swiftType : "receiver") + ".\(swiftName(declaration.name))"
    }
    let tryPrefix =
        (declaration.throwing || declaration.rethrowing ? "try " : "")
        + (declaration.isAsync ? "await " : "")
    var body = ""
    if !declaration.isStatic && declaration.kind != .initializer {
        body += receiverBinding(swiftType, receiverType, mutating: declaration.isMutating)
    }
    if !checked.isEmpty {
        body += preconditionLines(
            checked,
            parameters: declaration.parameters,
            conversions: conversions
        )
    }
    let isVoid = if case .tuple(let elements) = returns, elements.isEmpty { true } else { false }
    // A result that's an array is typed, so Swift picks the overload the
    // signature came from: `Sequence.dropLast() -> [Element]`, not the
    // Slice a Set's own Collection conformance would give.
    let resultType: String
    if case .array = returns { resultType = ": \(spelling(returns))" } else { resultType = "" }
    if declaration.isMutating {
        body +=
            isVoid
            ? "\(tryPrefix)\(target)\n                "
            : "let result\(resultType) = \(tryPrefix)\(target)\n                "
        body += mutatingReturn(returns, isVoid: isVoid)
    } else if isVoid {
        body += "\(tryPrefix)\(target)\n                return .nothing"
    } else {
        body +=
            "let result\(resultType) = \(tryPrefix)\(target)\n                return \(toValue("result", returns))"
    }
    // `var extension: String? { get set }`: a setter too, which changes a copy of the receiver
    // and gives it back, as a mutating method does.
    let setterBody = setterCode(
        declaration,
        text: text,
        swiftType: swiftType,
        receiverType: receiverType,
        returns: returns
    )
    // An `async` one is waited for in `suspend`, letting other tasks run.
    if declaration.isAsync {
        if declaration.isMutating { throw Unsupported(reason: "async mutating") }
        body =
            "return try Value.Bridging.awaiting(interpreter) { () async throws -> Value in\n\(body)\n                }"
    }
    // A key path reads fields as the host reads them, for as long as the call.
    if parameters.contains(where: { scriptType($0.1).hasPrefix(".named(.keyPath") }) {
        body =
            "return try Value.Bridging.withFieldReader(interpreter) { () throws -> Value in\n\(body)\n                }"
    }
    let code = describedMember(
        declaration,
        scriptName: renames["\(original.name).\(declaration.name)"] ?? declaration.name,
        symbol: symbol,
        parameters: parameterCode,
        returns: returns,
        generics: generics,
        body: body,
        setterBody: setterBody,
        isFree: isFree
    )
    return BridgedMember(key: key, shape: shape, code: code)
}
// swiftlint:enable cyclomatic_complexity function_body_length

/// The glue's first lines for a member with a receiver: it is read from `args["self"]`; a mutating
/// member's may come in a box, moved out of its variable so nothing else holds it while it changes
/// (a collection would be copied whole on every call), and the box gets it back, however the call
/// ends.
func receiverBinding(_ swiftType: String, _ receiverType: SType, mutating: Bool) -> String {
    guard mutating else {
        return
            "let receiver: \(swiftType) = \(fromValue("selfValue", receiverType))\n                "
    }
    // The receiver is set aside before it changes, so nothing else holds a collection in it.
    var conversion = fromValue("taken", receiverType)
    // Used once as an argument, `taken` ends there, so the receiver holds the only reference.
    if conversion.components(separatedBy: "taken").count == 2 {
        conversion = conversion.replacingOccurrences(of: "(taken)", with: "(consume taken)")
            .replacingOccurrences(of: "taken.unboxing(", with: "(consume taken).unboxing(")
    }
    return
        "let taken = selfValue\n                selfValue = .nothing\n                var receiver: \(swiftType) = \(conversion)\n                defer { selfValue = \(toValue("receiver", receiverType)) }\n                "
}

/// The end of a mutating member's glue: what it gives back. The receiver is put back by the
/// `defer` that `receiverBinding` writes.
func mutatingReturn(_ returns: SType, isVoid: Bool) -> String {
    "return \(isVoid ? ".nothing" : toValue("result", returns))"
}

/// A settable property's setter, which changes a copy of the receiver and gives it back, as a
/// mutating method does: the body of the property's `set`.
func setterCode(
    _ declaration: Declaration,
    text: String,
    swiftType: String,
    receiverType: SType,
    returns: SType
) -> String? {
    guard declaration.kind == .property, !declaration.isStatic, text.contains("set }") else {
        return nil
    }
    return """
        var receiver: \(swiftType) = \(fromValue("selfValue", receiverType))
        receiver.\(swiftName(declaration.name)) = \(fromValue("newValue", returns))
        return \(toValue("receiver", receiverType))
        """
}

/// Whether the module also declares the member with an array where `declaration` has variadic
/// arguments: the same name and labels, `[T]` for `T...`.
func hasArrayOverload(_ symbol: Symbol, _ declaration: Declaration) -> Bool {
    graph.symbols.contains { other in
        guard other.pathComponents == symbol.pathComponents,
            other.identifier.precise != symbol.identifier.precise,
            let text = Optional((other.declarationFragments ?? []).map(\.spelling).joined()),
            let sibling = try? parseDeclaration(text),
            sibling.name == declaration.name,
            sibling.parameters.count == declaration.parameters.count
        else { return false }
        return zip(declaration.parameters, sibling.parameters)
            .allSatisfy { mine, theirs in
                mine.label == theirs.label
                    && (mine.isVariadic
                        ? theirs.type == .array(mine.type) && !theirs.isVariadic
                        : mine.type == theirs.type && !theirs.isVariadic)
            }
    }
}
