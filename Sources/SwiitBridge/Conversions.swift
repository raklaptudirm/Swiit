import Foundation

func annotation(_ type: SType) -> String {
    switch type {
    case .named(let name, []): return leaves[name]?.annotation ?? ".parameter(\(quoted(name)))"
    case .named("KeyPath", let arguments) where arguments.count == 2: return ".keyPath(\(annotation(arguments[0])), \(annotation(arguments[1])))"
    case .named(let name, let arguments): return ".generic(\(quoted(name)), [\(arguments.map(annotation).joined(separator: ", "))])"
    case .array(let element): return ".list(\(annotation(element)))"
    case .optional(let wrapped): return ".optional(\(annotation(wrapped)))"
    case .dictionary(let key, let value): return ".dictionary(\(annotation(key)), \(annotation(value)))"
    case .someSequence(let element): return ".someSequence(\(annotation(element)))"
    case .tuple(let elements):
        if elements.isEmpty { return ".void" }
        return ".tuple([" + elements.map { ".init(label: \($0.label.map(quoted) ?? "nil"), type: \(annotation($0.type)))" }.joined(separator: ", ") + "])"
    case .function(let parameters, let result, let throwing):
        return ".functionType([\(parameters.map(annotation).joined(separator: ", "))], \(annotation(result)), throws: \(throwing))"
    case .member: fatalError("unsupported \(type)")
    }
}

/// How Swift spells `type`, with Swish's values for generic parameters.
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
        return "(" + elements.map { ($0.label.map { "\($0): " } ?? "") + spelling($0.type) }.joined(separator: ", ") + ")"
    case .function(let parameters, let result, let throwing):
        return "(\(parameters.map(spelling).joined(separator: ", ")))\(throwing ? " throws" : "") -> \(spelling(result))"
    case .member: fatalError("unsupported \(type)")
    }
}

/// A box's type as Swish holds it: its generic parameters all Swish values.
func canonical(_ name: String, _ arguments: [SType]) -> String {
    spelling(.named(name, arguments.map { _ in .named("Value", []) }))
}

/// Whether a type is a leaf, which converts, rather than a Swish value.
func isLeaf(_ type: SType) -> Bool {
    if case .named(let name, []) = type { return leaves[name] != nil }
    return false
}

/// Swift code turning the Swish value `value` into a `type`.
func fromSwish(_ value: String, _ type: SType) -> String {
    switch type {
    case .named(let name, []): return leaves[name]?.from(value) ?? value
    case .named("KeyPath", let arguments) where arguments.count == 2: return "try bridgeKeyPath(\(value))"
    case .named(let name, let arguments):
        let box = "try SwiftValue.unbox(\(canonical(name, arguments)).self, \(value))"
        guard arguments.contains(where: isLeaf) else { return box }
        switch name {
        case "Range", "ClosedRange": return "try bridge\(name)(\(value)) { \(fromSwish("$0", arguments[0])) }"
        default: return "\(spelling(type))(\(box).map { \(fromSwish("$0", arguments[0])) })"
        }
    case .array(let element), .someSequence(let element):
        let items = if case .array = type { "try bridgeList(\(value))" } else { "try bridgeSequence(\(value))" }
        if case .named(let name, []) = element, leaves[name] == nil { return items }
        return "\(items).map { \(fromSwish("$0", element)) }"
    case .optional(let wrapped):
        // A value that is a call (a closure's result) is made once, not once to
        // test and again to convert.
        guard !value.contains("(") else { return "try bridgeOptional(\(value)) { \(fromSwish("$0", wrapped)) }" }
        return "(\(value) == .nothing ? nil : \(fromSwish(value, wrapped)))"
    case .dictionary(let key, let value2):
        guard isLeaf(key) || isLeaf(value2) else { return "try bridgeDictionary(\(value))" }
        return "try Dictionary(uniqueKeysWithValues: bridgeDictionary(\(value)).map { (\(fromSwish("$0.key", key)), \(fromSwish("$0.value", value2))) })"
    case .tuple(let elements):
        let labels = elements.map { $0.label.map(quoted) ?? "nil" }.joined(separator: ", ")
        let parts = elements.enumerated().map { index, element in
            (element.label.map { "\($0): " } ?? "") + fromSwish("t[\(index)]", element.type)
        }
        return "try bridgeTuple(\(value), [\(labels)]) { t in (\(parts.joined(separator: ", "))) }"
    case .function(let parameters, let result, _):
        let names = parameters.indices.map { "a\($0)" }
        let arguments = zip(names, parameters).map { toSwish($0, $1) }.joined(separator: ", ")
        let typed = zip(names, parameters).map { "\($0): \(spelling($1))" }.joined(separator: ", ")
        let call = "try bridgeClosure(shell, \(value))([\(arguments)])"
        if case .tuple(let elements) = result, elements.isEmpty { return "{ (\(typed)) throws -> Void in _ = \(call) }" }
        return "{ (\(typed)) throws -> \(spelling(result)) in \(fromSwish(call, result)) }"
    case .member: fatalError("unsupported \(type)")
    }
}

/// Swift code turning `swift`, a `type`, into a Swish value.
func toSwish(_ swift: String, _ type: SType) -> String {
    switch type {
    case .named(let name, []): return leaves[name]?.to(swift) ?? swift
    case .named(let name, let arguments):
        let typeName = quoted(name)
        guard arguments.contains(where: isLeaf) else { return "SwiftValue.make(\(swift), as: \(typeName))" }
        let bound = arguments[0]
        switch name {
        case "Range", "ClosedRange":
            return "bridgeBox(\(swift), as: \(typeName)) { r in \(canonical(name, arguments))(uncheckedBounds: (lower: \(toSwish("r.lowerBound", bound)), upper: \(toSwish("r.upperBound", bound)))) }"
        default:
            return "bridgeBox(\(swift), as: \(typeName)) { \(canonical(name, arguments))($0.map { \(toSwish("$0", bound)) }) }"
        }
    case .array(let element):
        if case .named(let name, []) = element, leaves[name] == nil { return ".list(\(swift))" }
        return ".list(\(swift).map { \(toSwish("$0", element)) })"
    case .optional(let wrapped): return "(\(swift).map { \(toSwish("$0", wrapped)) } ?? .nothing)"
    case .dictionary(let key, let value):
        // In the receiver's order, as far as it goes.
        guard isLeaf(key) || isLeaf(value) else { return "bridgeDictionary(\(swift))" }
        return "bridgeDictionary(Dictionary(uniqueKeysWithValues: \(swift).map { (\(toSwish("$0.key", key)), \(toSwish("$0.value", value))) }))"
    case .tuple(let elements):
        if elements.isEmpty { return ".nothing" }
        let parts = elements.enumerated().map { index, element in
            "(\(element.label.map(quoted) ?? "nil"), \(toSwish("t.\(index)", element.type)))"
        }
        return "bridgeTuple(\(swift)) { t in [\(parts.joined(separator: ", "))] }"
    case .someSequence, .function, .member: fatalError("unsupported \(type)")
    }
}

/// A Swish `Value` literal for a default that is one, like `true` or `1`.
func literalDefault(_ text: String) -> String? {
    if text == "true" || text == "false" { return ".literal(.bool(\(text)))" }
    if Int(text) != nil { return ".literal(.int(\(text)))" }
    if Double(text) != nil { return ".literal(.double(\(text)))" }
    if text == "nil" { return ".literal(.nothing)" }
    if text.hasPrefix("\""), text.hasSuffix("\""), !text.contains("\\(") { return ".literal(.string(\(text)))" }
    return nil
}

/// A member's name as Swift code writes it: a keyword in backticks.
func swiftName(_ name: String) -> String {
    ["extension", "default", "func", "import", "in", "is", "as", "operator"].contains(name) ? "`\(name)`" : name
}

func quoted(_ text: String) -> String {
    "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}
