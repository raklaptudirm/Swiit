import Foundation

// A Swift member that is called with an argument it does not accept (an index past the end, a
// negative length) stops the process: a trap cannot be caught. The symbol graph does not say which
// members those are, so a table does (`Bridges/preconditions.json`), and the glue checks before it
// calls, and gives a script an error to read.

/// One condition under which a member would trap, and what a script is told instead.
struct Precondition: Decodable {
    /// The types that have the member (`Array`), or nil for every type that does.
    let types: [String]?
    /// The member as Swift names it with its labels: `remove(at:)`, `index(_:offsetBy:)`.
    let member: String
    /// The Swift types of its parameters, if only some overloads trap (`init(_:)` of a `Double`).
    let parameters: [String]?
    /// Swift: true when the call would trap. A parameter is named by its label, or `_0`, `_1`… by
    /// its place if it has none; `self` is the receiver. Without it, the entry says that the member
    /// was looked at and cannot trap (`safe` says why), and is not listed as unchecked.
    let when: String?
    /// What the script reads. It may interpolate the parameters: `\(at)`.
    let error: String?
    /// Why the member cannot trap, for an entry without a condition.
    let safe: String?
}

// safe: the generator runs on one thread
nonisolated(unsafe) var preconditions: [Precondition] = []

/// Reads the table of `--preconditions <file>`.
func loadPreconditions(_ path: String) throws {
    preconditions += try JSONDecoder()
        .decode(
            [Precondition].self,
            from: Data(contentsOf: URL(fileURLWithPath: path))
        )
}

/// `remove(at:)`, `index(_:offsetBy:)`, `count`: how a table names a member.
func memberKey(_ declaration: Declaration) -> String {
    let labels = declaration.parameters.map { ($0.label ?? "_") + ":" }.joined()
    return declaration.parameters.isEmpty && declaration.kind == .property
        ? declaration.name : "\(declaration.name)(\(labels))"
}

/// The conditions that apply to a member of `typeName`.
func applicablePreconditions(
    of typeName: String,
    _ declaration: Declaration,
    parameterTypes: [String]
) -> [Precondition] {
    let key = memberKey(declaration)
    return preconditions.filter { entry in
        entry.member == key && (entry.types?.contains(typeName) ?? true)
            && (entry.parameters == nil || entry.parameters == parameterTypes)
    }
}

/// The name a parameter has in a condition: its label, or its place.
func conditionVariable(_ parameter: Parameter, at index: Int) -> String {
    guard let label = parameter.label else { return "_\(index)" }
    return swiftKeywords.contains(label) ? "`\(label)`" : label
}

private let swiftKeywords: Set<String> = [
    "in", "where", "for", "if", "is", "as", "do", "let", "var", "func", "init", "self", "default",
]

/// The glue's lines for a member with conditions: its parameters, converted once and named, and
/// each check before the call. The receiver is `receiver`.
func preconditionLines(
    _ entries: [Precondition],
    parameters: [Parameter],
    conversions: [String]
) -> String {
    var lines = zip(parameters.indices, zip(parameters, conversions))
        .map { index, pair in
            "let \(conditionVariable(pair.0, at: index)) = \(pair.1)"
        }
    for entry in entries {
        guard let when = entry.when, let error = entry.error else { continue }
        let condition = when.replacingOccurrences(
            of: #"\bself\b"#,
            with: "receiver",
            options: .regularExpression
        )
        let message = error.replacingOccurrences(of: "\"", with: "\\\"")
        lines.append("try Value.Bridging.require(!(\(condition)), \"\(message)\")")
    }
    return lines.joined(separator: "\n                ") + "\n                "
}

// MARK: Members that look as if they can trap, and have no entry

private let namesOfPositions: Set<String> = [
    "at", "index", "i", "j", "n", "k", "offset", "offsetBy", "count", "position", "maxLength",
    "maxSplits", "limit", "bitWidth", "by", "dividingBy", "to", "from",
]

/// Whether a type is, or names, an index.
private func isAnIndex(_ type: SType) -> Bool {
    switch type {
    case .named(let name, _): return name.hasSuffix("Index")
    case .member(_, let name): return name == "Index"
    default: return false
    }
}

/// Whether a member's shape is one that traps on some arguments: it takes an integer by a name that
/// says where, or an index, or it removes the first or last element of what may be empty. A guess,
/// which only makes a list to read.
func looksAsIfItCanTrap(_ declaration: Declaration) -> Bool {
    guard declaration.kind != .property else { return false }
    if ["removeFirst", "removeLast"].contains(declaration.name) { return true }
    return declaration.parameters.contains { parameter in
        if isAnIndex(parameter.type) { return true }
        if case .named("Int", []) = parameter.type {
            return namesOfPositions.contains(parameter.label ?? parameter.name)
        }
        return false
    }
}

// safe: the generator runs on one thread
nonisolated(unsafe) var uncheckedMembers: [String] = []
