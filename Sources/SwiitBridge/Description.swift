import Foundation

// The output: a description of the types (`ImplementedType` and `ImplementedSymbol`), which compiles in any
// package that imports Swiit.

/// `type` as the `TypeExpression` the description's signatures are written in.
func typeExpression(_ type: SType) -> String {
    switch type {
    case .named(let name, []):
        guard leaves[name] != nil else { return ".parameter(\(quoted(name)))" }
        return ["Int", "Double", "Bool", "String"].contains(name)
            ? ".\(name.lowercased())" : hostType(name)
    case .named("KeyPath", let arguments) where arguments.count == 2:
        return ".named(.keyPath, [\(arguments.map(typeExpression).joined(separator: ", "))])"
    case .named(let name, let arguments):
        return "\(hostType(name, arguments))"
    case .array(let element): return ".list(\(typeExpression(element)))"
    case .optional(let wrapped): return ".optional(\(typeExpression(wrapped)))"
    case .dictionary(let key, let value):
        return ".dictionary(\(typeExpression(key)), \(typeExpression(value)))"
    case .someSequence(let element): return ".named(.sequence, [\(typeExpression(element))])"
    case .tuple(let elements):
        if elements.isEmpty { return ".void" }
        return ".tuple(["
            + elements.map {
                ".init(label: \($0.label.map(quoted) ?? "nil"), type: \(typeExpression($0.type)))"
            }
            .joined(separator: ", ") + "])"
    case .function(let parameters, let result, let throwing, let isAsync):
        // A parameter the function changes in place is a function-type parameter of its own.
        guard parameters.contains(where: { if case .inOut = $0 { true } else { false } }) else {
            return
                ".function(parameters: [\(parameters.map(typeExpression).joined(separator: ", "))], returns: \(typeExpression(result)), isThrowing: \(throwing), isAsync: \(isAsync))"
        }
        let described = parameters.map { parameter -> String in
            if case .inOut(let inner) = parameter {
                return ".init(\(typeExpression(inner)), isInout: true)"
            }
            return ".init(\(typeExpression(parameter)))"
        }
        return
            ".function(TypeExpression.FunctionType(parameters: [\(described.joined(separator: ", "))], returns: \(typeExpression(result)), throwing: \(throwing ? ".any" : ".no"), isAsync: \(isAsync)))"
    case .inOut(let inner): return typeExpression(inner)
    case .held(let element): return ".list(\(typeExpression(element)))"
    case .member: fatalError("unsupported \(type)")
    }
}

/// A type of the host, by name, with the types it is generic over.
func hostType(_ name: String, _ arguments: [SType] = []) -> String {
    ".named(.init(nativeType: \(quoted(name)))"
        + (arguments.isEmpty
            ? ")" : ", [\(arguments.map(typeExpression).joined(separator: ", "))])")
}

/// What a parameter's `Symbol.Parameter` says of whether a call may leave it out.
func arityCode(of parameter: Parameter, type: SType) throws -> String {
    if parameter.isVariadic { return ", arity: .variadic" }
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

/// The type parameters of a declaration with what each is constrained to, as generic parameter symbols.
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
                ? ".genericParameter(\(quoted(name)))"
                : ".genericParameter(\(quoted(name)), constraints: ["
                    + constraints.flatMap(constraint).joined(separator: ", ") + "])"
        }
        .joined(separator: ", ") + "]"
}

// swiftlint:disable function_parameter_count - it threads one state through; splitting it is item 17 of Docs/agenda.md
/// The `ImplementedSymbol` for a member, written as the description: its signature, and the glue as the
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
    isFree: Bool = false,
    updates: Bool = false
) -> String {
    let text = (symbol.declarationFragments ?? []).map(\.spelling).joined()
    let interpreter =
        body.contains("interpreter") ? "let interpreter = Interpreter.running!\n" : ""
    let throwing =
        declaration.rethrowing ? ".rethrowing" : declaration.throwing ? ".any" : ".no"
    let signature =
        "Symbol.Function(parameters: [\(parameterCode.joined(separator: ", "))], returns: \(typeExpression(returns)), throwing: \(throwing), isAsync: \(declaration.isAsync), generics: \(genericParametersDescription(generics)))"
    let head =
        "\(quoted(scriptName)), summary: \(quoted(symbol.summary)), \(attributesCode(of: text))"
    let code: String
    switch declaration.kind {
    case .initializer:
        code =
            "ImplementedSymbol.initializer(summary: \(quoted(symbol.summary)), \(attributesCode(of: text))signature: \(signature)) { arguments in\n\(interpreter)\(body)\n}"
    case .property where declaration.isStatic:
        code =
            "ImplementedSymbol.staticProperty(\(head)type: \(typeExpression(returns)), get: {\n\(interpreter)\(body)\n})"
    case .property:
        let receiverBody = "selfValue in\n\(interpreter)\(body)\n}"
        let set = setterBody.map { ", set: { selfValue, newValue in\n\($0)\n}" } ?? ""
        code =
            "ImplementedSymbol.property(\(head)type: \(typeExpression(returns)), get: { \(receiverBody)\(set))"
    case .method where isFree:
        code =
            "ImplementedSymbol.function(name: \(quoted(scriptName)), summary: \(quoted(symbol.summary)), \(attributesCode(of: text))signature: \(signature), \(updates ? "updating" : "body"): { arguments in\n\(interpreter)\(body)\n})"
    case .method where declaration.isStatic:
        code =
            "ImplementedSymbol.staticMethod(\(head)signature: \(signature)) { arguments in\n\(interpreter)\(body)\n}"
    case .method:
        code =
            "ImplementedSymbol.\(declaration.isMutating ? "mutatingMethod" : "method")(\(head)signature: \(signature)) { selfValue, arguments in\n\(interpreter)\(body)\n}"
    }
    return code
}
// swiftlint:enable function_parameter_count

/// A `Symbol.Parameter` for a parameter of a member.
func describedParameter(_ parameter: Parameter, _ type: SType) throws -> String {
    let arity = try arityCode(of: parameter, type: type)
    var isInout = ""
    if case .inOut = type { isInout = ", isInout: true" }
    return
        "Symbol.Parameter(label: \(parameter.label.map(quoted) ?? "nil"), name: \(quoted(parameter.name)), type: \(typeExpression(type))\(isInout)\(arity))"
}
