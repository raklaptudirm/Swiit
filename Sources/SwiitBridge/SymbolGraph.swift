import Foundation

// MARK: The symbol graph

struct Fragment: Decodable { let kind: String; let spelling: String }
struct Version: Decodable { let major: Int; let minor: Int? }
struct Availability: Decodable {
    let domain: String?
    let isUnconditionallyDeprecated: Bool?
    let isUnconditionallyUnavailable: Bool?
    let deprecated: Version?
    let obsoleted: Version?
    let introduced: Version?
}
struct Constraint: Decodable { var kind: String; var lhs: String; var rhs: String }
struct Symbol: Decodable {
    struct Kind: Decodable { let identifier: String }
    struct Identifier: Decodable { let precise: String }
    struct Extension: Decodable { let constraints: [Constraint]? }
    struct Generics: Decodable { let constraints: [Constraint]? }
    struct Doc: Decodable { struct Line: Decodable { let text: String }; let lines: [Line] }
    let kind: Kind
    let identifier: Identifier
    let pathComponents: [String]
    let declarationFragments: [Fragment]?
    let swiftExtension: Extension?
    let swiftGenerics: Generics?
    let availability: [Availability]?
    let accessLevel: String
    let docComment: Doc?
    struct Location: Decodable { struct Position: Decodable { let line: Int }; let position: Position }
    let location: Location?

    /// The documentation's lines. A declaration that starts with an attribute (`@_spi(Layer)`) has the attribute's `@` in the
    /// last line, which the compiler's range takes in.
    private var docLines: [String] {
        (docComment?.lines ?? []).map { line in
            var text = line.text
            if text.hasSuffix("\n@") { text.removeLast(2) }
            return text.trimmingCharacters(in: .whitespaces)
        }
    }

    /// Its documentation's first paragraph, on one line: what `help` shows.
    var summary: String {
        let lines = docLines
        return lines.drop { $0.isEmpty }.prefix { !$0.isEmpty && !$0.hasPrefix("- ") }.joined(separator: " ")
    }

    /// Its `- Parameter name: text` lines, for `help`'s flags.
    var parameterDocs: [String: String] {
        var docs: [String: String] = [:]
        for line in docLines {
            guard line.hasPrefix("- Parameter "), let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.index(line.startIndex, offsetBy: 12)..<colon].trimmingCharacters(in: .whitespaces)
            docs[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return docs
    }
}
struct Relationship: Decodable {
    let kind: String; let source: String; let target: String; let targetFallback: String?
    let swiftConstraints: [Constraint]?
}
struct Graph: Decodable {
    struct Module: Decodable { let name: String }
    let module: Module
    let symbols: [Symbol]
    let relationships: [Relationship]
}
