import Foundation

/// The module's types held as they are, from another module: a FilePath.
nonisolated(unsafe) var externalTypes: Set<String> = []

/// A field's type as Swish source, and what encoding leaves for the glue to
/// fix (an enum or a path is text there); nil if Swish can't hold it so.
func fieldType(_ type: SType) -> (source: String, patch: String?)? {
    switch type {
    case .named(let name, []):
        if enumNames.contains(name) { return (name, ".enumeration(\(quoted(name)))") }
        // A Swift type held as it is (a FilePath, a FileSize), which encoding
        // loses: the glue boxes the field from the Swift value.
        if externalTypes.contains(name) { return (name, ".boxed(\(quoted(name)))") }
        // A value kind Swish has itself (Int, String, Date…), which encoding keeps.
        if let leaf = leaves[name], !leaf.annotation.hasPrefix(".named") { return (name, nil) }
        return nil
    case .array(let element):
        // Patches are by field, not by item.
        guard let found = fieldType(element), found.patch == nil else { return nil }
        return ("[\(found.source)]", nil)
    case .optional(let wrapped): return fieldType(wrapped).map { ("\($0.source)?", $0.patch) }
    default: return nil
    }
}

func publicMembers(of name: String, _ kind: String) -> [Symbol] {
    graph.symbols.filter { $0.pathComponents.count == 2 && $0.pathComponents[0] == name
        && $0.kind.identifier == kind && $0.accessLevel == "public" }
        // In declaration order, which the graph gives as source lines.
        .sorted { ($0.location?.position.line ?? 0) < ($1.location?.position.line ?? 0) }
}

func conformances(of symbol: Symbol, among kept: [String]) -> [String] {
    let all = graph.relationships.filter { $0.kind == "conformsTo" && $0.source == symbol.identifier.precise }
        .compactMap { $0.targetFallback.map { String($0.split(separator: ".").last!) } }
    return kept.filter(all.contains)
}

func declaredType(_ symbol: Symbol) -> String {
    symbol.summary.isEmpty ? "" : "/// \(symbol.summary)\n"
}
