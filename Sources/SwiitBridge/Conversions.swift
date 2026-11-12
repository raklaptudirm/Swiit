import Foundation

/// How Swift spells `type`, with Swiit's values for generic parameters.
func spelling(_ type: SType) -> String {
    switch type {
    case .named(let name, []): return leaves[name] != nil ? name : "Value"
    case .named(let name, let arguments):
        return "\(name)<\(arguments.map(spelling).joined(separator: ", "))>"
    case .array(let element), .someSequence(let element): return "[\(spelling(element))]"
    case .optional(let wrapped): return "\(spelling(wrapped))?"
    case .dictionary(let key, let value): return "[\(spelling(key)): \(spelling(value))]"
    case .tuple(let elements):
        if elements.isEmpty { return "Void" }
        return "("
            + elements.map { ($0.label.map { "\($0): " } ?? "") + spelling($0.type) }
            .joined(separator: ", ")
            + ")"
    case .function(let parameters, let result, let throwing, let isAsync):
        return
            "(\(parameters.map(spelling).joined(separator: ", ")))\(isAsync ? " async" : "")\(throwing ? " throws" : "") -> \(spelling(result))"
    case .inOut(let inner): return "inout \(spelling(inner))"
    case .held(let element): return "[\(spelling(element))]"
    case .member: fatalError("unsupported \(type)")
    }
}

/// A box's type as Swiit holds it: its generic parameters all Swiit values.
func canonical(_ name: String, _ arguments: [SType]) -> String {
    spelling(.named(name, arguments.map { _ in .named("Value", []) }))
}

/// Whether a type is a leaf, which converts, rather than a Swiit value.
func isLeaf(_ type: SType) -> Bool {
    if case .named(let name, []) = type { return leaves[name] != nil }
    return false
}

/// Swift code turning the Swiit value `value` into a `type`.
func fromValue(_ value: String, _ type: SType) -> String {
    switch type {
    case .named(let name, []): return leaves[name]?.from(value) ?? value
    case .named("KeyPath", let arguments) where arguments.count == 2:
        return "try Value.Bridging.keyPath(\(value))"
    case .named(let name, let arguments):
        let box = "try \(value).unboxing(\(canonical(name, arguments)).self)"
        guard arguments.contains(where: isLeaf) else { return box }
        switch name {
        case "Range", "ClosedRange":
            let function = name == "Range" ? "range" : "closedRange"
            return "try Value.Bridging.\(function)(\(value)) { \(fromValue("$0", arguments[0])) }"
        default: return "\(spelling(type))(\(box).map { \(fromValue("$0", arguments[0])) })"
        }
    case .array(let element), .someSequence(let element):
        let items =
            if case .array = type { "try Value.Bridging.list(\(value))" } else {
                "try Value.Bridging.sequence(\(value))"
            }
        if case .named(let name, []) = element, leaves[name] == nil { return items }
        return "\(items).map { \(fromValue("$0", element)) }"
    case .optional(let wrapped):
        // A value that is a call (a closure's result) is made once, not once to
        // test and again to convert.
        guard !value.contains("(") else {
            // The `try` is for the closure; what is inside the parentheses has its own.
            let converted = fromValue("$0", wrapped)
            return
                "\(converted.contains("try") ? "try " : "")Value.Bridging.optional(\(value)) { \(converted) }"
        }
        return "(\(value) == .nothing ? nil : \(fromValue(value, wrapped)))"
    case .dictionary(let key, let value2):
        guard isLeaf(key) || isLeaf(value2) else {
            return "try Value.Bridging.dictionary(\(value))"
        }
        return
            "try Dictionary(uniqueKeysWithValues: Value.Bridging.dictionary(\(value)).map { (\(fromValue("$0.key", key)), \(fromValue("$0.value", value2))) })"
    case .tuple(let elements):
        let labels = elements.map { $0.label.map(quoted) ?? "nil" }.joined(separator: ", ")
        let parts = elements.enumerated()
            .map { index, element in
                (element.label.map { "\($0): " } ?? "") + fromValue("t[\(index)]", element.type)
            }
        return
            "try Value.Bridging.tuple(\(value), [\(labels)]) { t in (\(parts.joined(separator: ", "))) }"
    case .function(let parameters, let result, _, _)
    where parameters.contains(where: { if case .inOut = $0 { true } else { false } }):
        // `(inout A, B) -> R`: the script closure's changed arguments come back with its result
        // (`Value.Bridging.changing`), and the ones Swift passed in place are set to them.
        let names = parameters.indices.map { "a\($0)" }
        var inPlace: [Int] = []
        var typed: [String] = []
        var passed: [String] = []
        for (index, parameter) in parameters.enumerated() {
            if case .inOut(let inner) = parameter {
                inPlace.append(index)
                typed.append("\(names[index]): inout \(spelling(inner))")
                passed.append(toValue(names[index], inner))
            } else {
                typed.append("\(names[index]): \(spelling(parameter))")
                passed.append(toValue(names[index], parameter))
            }
        }
        let positions = inPlace.map(String.init).joined(separator: ", ")
        var lines = [
            "let outcome = try Value.Bridging.changing(interpreter, \(value), [\(passed.joined(separator: ", "))], at: [\(positions)])"
        ]
        for (slot, index) in inPlace.enumerated() {
            guard case .inOut(let inner) = parameters[index] else { continue }
            lines.append("\(names[index]) = \(fromValue("outcome.changed[\(slot)]", inner))")
        }
        let isVoid = if case .tuple(let elements) = result, elements.isEmpty { true } else { false }
        if !isVoid { lines.append("return \(fromValue("outcome.result", result))") }
        return
            "{ (\(typed.joined(separator: ", "))) throws -> \(isVoid ? "Void" : spelling(result)) in\n\(lines.joined(separator: "\n"))\n}"
    case .function(let parameters, let result, _, let isAsync):
        let names = parameters.indices.map { "a\($0)" }
        let arguments = zip(names, parameters).map { toValue($0, $1) }.joined(separator: ", ")
        let typed = zip(names, parameters).map { "\($0): \(spelling($1))" }.joined(separator: ", ")
        // A closure Swift calls as `async` runs on a thread of the interpreter's
        // (`bridgeAsyncClosure`), as the task that passed it.
        let call =
            isAsync
            ? "(try await Value.Bridging.asyncClosure(interpreter, \(value))([\(arguments)]))"
            : "try Value.Bridging.closure(interpreter, \(value))([\(arguments)])"
        let effects = isAsync ? "async throws" : "throws"
        if case .tuple(let elements) = result, elements.isEmpty {
            return "{ (\(typed)) \(effects) -> Void in _ = \(call) }"
        }
        return "{ (\(typed)) \(effects) -> \(spelling(result)) in \(fromValue(call, result)) }"
    case .inOut, .held: fatalError("unsupported \(type)")
    case .member: fatalError("unsupported \(type)")
    }
}

/// Swift code turning `swift`, a `type`, into a Swiit value.
func toValue(_ swift: String, _ type: SType) -> String {
    switch type {
    case .named(let name, []): return leaves[name]?.to(swift) ?? swift
    case .named(let name, let arguments):
        let typeName = quoted(name)
        guard arguments.contains(where: isLeaf) else {
            return "Value(boxing: \(swift), as: .init(hostType: \(typeName)))"
        }
        let bound = arguments[0]
        switch name {
        case "Range", "ClosedRange":
            return
                "Value.Bridging.box(\(swift), as: .init(hostType: \(typeName))) { r in \(canonical(name, arguments))(uncheckedBounds: (lower: \(toValue("r.lowerBound", bound)), upper: \(toValue("r.upperBound", bound)))) }"
        default:
            return
                "Value.Bridging.box(\(swift), as: .init(hostType: \(typeName))) { \(canonical(name, arguments))($0.map { \(toValue("$0", bound)) }) }"
        }
    case .array(let element):
        if case .named(let name, []) = element, leaves[name] == nil {
            return "Value(list: \(swift))"
        }
        return "Value(list: \(swift).map { \(toValue("$0", element)) })"
    case .optional(let wrapped): return "(\(swift).map { \(toValue("$0", wrapped)) } ?? .nothing)"
    case .dictionary(let key, let value):
        // In the receiver's order, as far as it goes.
        guard isLeaf(key) || isLeaf(value) else { return "Value.Bridging.dictionary(\(swift))" }
        return
            "Value.Bridging.dictionary(Dictionary(uniqueKeysWithValues: \(swift).map { (\(toValue("$0.key", key)), \(toValue("$0.value", value))) }))"
    case .tuple(let elements):
        if elements.isEmpty { return ".nothing" }
        let parts = elements.enumerated()
            .map { index, element in
                "(\(element.label.map(quoted) ?? "nil"), \(toValue("t.\(index)", element.type)))"
            }
        return "Value.Bridging.tuple(\(swift)) { t in [\(parts.joined(separator: ", "))] }"
    case .held(let element):
        // Swift's sequence, as the array it gives.
        if case .named(let name, []) = element, leaves[name] == nil {
            return "Value(list: Array(\(swift)))"
        }
        return "Value(list: Array(\(swift)).map { \(toValue("$0", element)) })"
    case .someSequence, .function, .inOut, .member: fatalError("unsupported \(type)")
    }
}

/// A Swiit `Value` literal for a default that is one, like `true` or `1`.
func literalDefault(_ text: String) -> String? {
    if text == "true" || text == "false" { return ".literal(.bool(\(text)))" }
    if Int(text) != nil { return ".literal(.int(\(text)))" }
    if Double(text) != nil { return ".literal(.double(\(text)))" }
    if text == "nil" { return ".literal(.nothing)" }
    if text.hasPrefix("\""), text.hasSuffix("\""), !text.contains("\\(") {
        return ".literal(.string(\(text)))"
    }
    return nil
}

/// A member's name as Swift code writes it: a keyword in backticks.
func swiftName(_ name: String) -> String {
    ["extension", "default", "func", "import", "in", "is", "as", "operator"].contains(name)
        ? "`\(name)`" : name
}

func quoted(_ text: String) -> String {
    "\""
        + text.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

/// The attributes written at the start of a declaration (`@discardableResult mutating func …`), as
/// the code that makes them, ending in `", "` for a place before another argument; nothing when
/// there are none. The compiler's underscored ones are left out.
func attributesCode(of declaration: String) -> String {
    var rest = Substring(declaration.drop { $0.isWhitespace })
    var made: [String] = []
    while rest.first == "@" {
        rest = rest.dropFirst()
        let name = String(rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
        rest = rest.dropFirst(name.count)
        var arguments: [String] = []
        if rest.first == "(" {
            var depth = 0
            var current = ""
            var consumed = 0
            for character in rest {
                consumed += 1
                if character == "(" {
                    depth += 1
                    if depth == 1 { continue }
                } else if character == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
                if character == ",", depth == 1 {
                    arguments.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                } else {
                    current.append(character)
                }
            }
            if !current.isEmpty { arguments.append(current.trimmingCharacters(in: .whitespaces)) }
            rest = rest.dropFirst(consumed)
        }
        rest = Substring(rest.drop { $0.isWhitespace })
        if name.hasPrefix("_") { continue }
        let argumentsCode =
            arguments.isEmpty
            ? "" : ", arguments: [\(arguments.map(quoted).joined(separator: ", "))]"
        made.append("Symbol.Attribute(name: \(quoted(name))\(argumentsCode))")
    }
    return made.isEmpty ? "" : "attributes: [\(made.joined(separator: ", "))], "
}

/// The type parameters of a declaration with what each is constrained to, as the code that makes
/// them (`["Element", GenericParameter(name: "K", constraints: [.conforms(to: "Hashable")])]`). A
/// constraint is a protocol, or `=Type` for exactly that type.
func genericParametersCode(_ generics: [String: [String]]) -> String {
    func constraint(_ text: String) -> [String] {
        text.components(separatedBy: " & ")
            .map {
                $0.hasPrefix("=")
                    ? ".equals(\(quoted(String($0.dropFirst()))))" : ".conforms(to: \(quoted($0)))"
            }
    }
    return "["
        + generics.sorted { $0.key < $1.key }
        .map { name, constraints in
            constraints.isEmpty
                ? quoted(name)
                : "GenericParameter(name: \(quoted(name)), constraints: ["
                    + constraints.flatMap(constraint).joined(separator: ", ") + "])"
        }
        .joined(separator: ", ") + "]"
}
