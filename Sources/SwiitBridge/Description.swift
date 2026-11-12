import Foundation

// The output: a description of the types (`HostType` and `HostSymbol`), which compiles in any
// package that imports Swiit.

/// `type` as the `ScriptType` the description's signatures are written in.
func scriptType(_ type: SType) -> String {
    switch type {
    case .named(let name, []):
        guard leaves[name] != nil else { return ".parameter(\(quoted(name)))" }
        return ["Int", "Double", "Bool", "String"].contains(name)
            ? ".\(name.lowercased())" : hostType(name)
    case .named("KeyPath", let arguments) where arguments.count == 2:
        return ".named(.keyPath, [\(arguments.map(scriptType).joined(separator: ", "))])"
    case .named(let name, let arguments):
        return "\(hostType(name, arguments))"
    case .array(let element): return ".list(\(scriptType(element)))"
    case .optional(let wrapped): return ".optional(\(scriptType(wrapped)))"
    case .dictionary(let key, let value):
        return ".dictionary(\(scriptType(key)), \(scriptType(value)))"
    case .someSequence(let element): return ".named(.sequence, [\(scriptType(element))])"
    case .tuple(let elements):
        if elements.isEmpty { return ".void" }
        return ".tuple(["
            + elements.map {
                ".init(label: \($0.label.map(quoted) ?? "nil"), type: \(scriptType($0.type)))"
            }
            .joined(separator: ", ") + "])"
    case .function(let parameters, let result, let throwing, let isAsync):
        return
            ".function(parameters: [\(parameters.map(scriptType).joined(separator: ", "))], returns: \(scriptType(result)), isThrowing: \(throwing), isAsync: \(isAsync))"
    case .member: fatalError("unsupported \(type)")
    }
}

/// A type of the host, by name, with the types it is generic over.
func hostType(_ name: String, _ arguments: [SType] = []) -> String {
    ".named(.init(hostType: \(quoted(name)))"
        + (arguments.isEmpty ? ")" : ", [\(arguments.map(scriptType).joined(separator: ", "))])")
}

/// What a parameter's `Symbol.Parameter` says of whether a call may leave it out.
func arityCode(of parameter: Parameter, type: SType) throws -> String {
    guard let text = parameter.defaultText else { return "" }
    if text == "true" || text == "false" || Int(text) != nil || Double(text) != nil
        || (text.hasPrefix("\"") && text.hasSuffix("\"") && !text.contains("\\("))
    {
        return ", arity: .defaulted(.value(\(text)))"
    }
    if text == "nil" { return ", arity: .defaulted(.value(.nothing))" }
    // The description cannot tell a left-out argument from a nil one, which a default that only
    // Swift can make would need for an optional.
    if case .optional = type { throw Unsupported(reason: "computed default of optional") }
    return ", arity: .defaulted(.computed)"
}

/// The type parameters of a declaration with what each is constrained to, as `Symbol.GenericParameter`s.
func genericParametersDescription(_ generics: [String: [String]]) -> String {
    func constraint(_ text: String) -> [String] {
        text.components(separatedBy: " & ")
            .map {
                $0.hasPrefix("=")
                    ? ".equals(\(hostType(String($0.dropFirst()))))"
                    : ".conforms(to: \(hostType($0)))"
            }
    }
    return "["
        + generics.sorted { $0.key < $1.key }
        .map { name, constraints in
            constraints.isEmpty
                ? quoted(name)
                : "Symbol.GenericParameter(name: \(quoted(name)), constraints: ["
                    + constraints.flatMap(constraint).joined(separator: ", ") + "])"
        }
        .joined(separator: ", ") + "]"
}

/// The `HostSymbol` for a member, written as the description: its signature, and the glue as the
/// body of the closure that runs it.
func describedMember(
    _ declaration: Declaration,
    scriptName: String,
    symbol: Symbol,
    parameters parameterCode: [String],
    returns: SType,
    generics: [String: [String]],
    body: String,
    setterBody: String?,
    isFree: Bool = false
) -> String {
    let text = (symbol.declarationFragments ?? []).map(\.spelling).joined()
    let interpreter =
        body.contains("interpreter") ? "let interpreter = Interpreter.running!\n" : ""
    let throwing =
        declaration.rethrowing ? ".rethrowing" : declaration.throwing ? ".any" : ".no"
    let signature =
        "Symbol.Function(parameters: [\(parameterCode.joined(separator: ", "))], returns: \(scriptType(returns)), throwing: \(throwing), isAsync: \(declaration.isAsync), generics: \(genericParametersDescription(generics)))"
    let head =
        "\(quoted(scriptName)), summary: \(quoted(symbol.summary)), \(attributesCode(of: text))"
    let code: String
    switch declaration.kind {
    case .initializer:
        code =
            "HostSymbol.initializer(summary: \(quoted(symbol.summary)), \(attributesCode(of: text))signature: \(signature)) { arguments in\n\(interpreter)\(body)\n}"
    case .property where declaration.isStatic:
        code =
            "HostSymbol.staticProperty(\(head)type: \(scriptType(returns)), get: {\n\(interpreter)\(body)\n})"
    case .property:
        let receiverBody = "selfValue in\n\(interpreter)\(body)\n}"
        let set = setterBody.map { ", set: { selfValue, newValue in\n\($0)\n}" } ?? ""
        code =
            "HostSymbol.property(\(head)type: \(scriptType(returns)), get: { \(receiverBody)\(set))"
    case .method where isFree:
        code =
            "HostSymbol.function(name: \(quoted(scriptName)), summary: \(quoted(symbol.summary)), parameters: [\(parameterCode.joined(separator: ", "))], returns: \(scriptType(returns)), isThrowing: \(declaration.throwing || declaration.rethrowing), generics: \(genericParametersDescription(generics)), \(attributesCode(of: text))body: { arguments in\n\(interpreter)\(body)\n})"
    case .method where declaration.isStatic:
        code =
            "HostSymbol.staticMethod(\(head)signature: \(signature)) { arguments in\n\(interpreter)\(body)\n}"
    case .method:
        code =
            "HostSymbol.\(declaration.isMutating ? "mutatingMethod" : "method")(\(head)signature: \(signature)) { selfValue, arguments in\n\(interpreter)\(body)\n}"
    }
    return code
}

/// A `Symbol.Parameter` for a parameter of a member.
func describedParameter(_ parameter: Parameter, _ type: SType) throws -> String {
    let arity = try arityCode(of: parameter, type: type)
    return
        "Symbol.Parameter(label: \(parameter.label.map(quoted) ?? "nil"), name: \(quoted(parameter.name)), type: \(scriptType(type))\(arity))"
}
