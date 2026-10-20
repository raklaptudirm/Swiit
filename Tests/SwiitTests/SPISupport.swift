import Foundation

/// The core's SPI: what it lets a syntax layer use without making it public
/// API. What any host needs is public; `Layer` is what a layer like the
/// shell's builds on (the tree, the parser, the checker, the hooks for running
/// what it parsed). The evaluator's insides are internal. Each
/// declaration is listed in spi-surface.txt, so a new one is a decision, and
/// the list only shrinks as they become public API or internal
/// (Docs/extraction.md, stages 1 and 2).
enum SPISurface {
    private static let here = URL(fileURLWithPath: #filePath)
    private static let sources = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Swiit")
    static let ledger = here.deletingLastPathComponent().appendingPathComponent("spi-surface.txt")

    private static let declaration = try! NSRegularExpression(pattern:
        #"@_spi\((Layer)\)\s+public\s+(?:(?:static|final|indirect|mutating|nonisolated\(unsafe\)|override|convenience|required|lazy|weak|unowned)\s+)*(func|var|let|init|class|struct|enum|protocol|typealias|case|subscript)\b\s*([A-Za-z_][A-Za-z0-9_]*|[^\s(<:]+)?"#)

    /// Each SPI declaration, as `file<TAB>group kind name`, in order.
    static func current() throws -> [String] {
        var entries: [String] = []
        let files = FileManager.default.enumerator(atPath: sources.path)!.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }
        for file in files.sorted() {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for match in declaration.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let group = String(text[Range(match.range(at: 1), in: text)!])
                let kind = String(text[Range(match.range(at: 2), in: text)!])
                let name = Range(match.range(at: 3), in: text).map { String(text[$0]) } ?? kind
                entries.append("\(file)\t\(group) \(kind) \(kind == "init" || kind == "subscript" ? kind : name)")
            }
        }
        return entries.sorted()
    }

    /// What differs from the ledger, one line each; empty when they agree.
    ///
    /// With `SWIIT_SPI_SHRINK=1` in the environment, lines for declarations that are no longer SPI are removed from the
    /// ledger first: the list only shrinks, so that is mechanical. A new declaration is never added this way; listing it
    /// is a decision, made by writing its line.
    static func differences() throws -> [String] {
        if ProcessInfo.processInfo.environment["SWIIT_SPI_SHRINK"] != nil { try dropStaleLines() }
        // For a deliberate change of what is SPI (a demotion from public API): the ledger is written from the source.
        if ProcessInfo.processInfo.environment["SWIIT_SPI_WRITE"] != nil { try writeLedger() }
        let listed = try String(contentsOf: ledger, encoding: .utf8).split(separator: "\n")
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }.map(String.init)
        var remaining = Dictionary(listed.map { ($0, 1) }, uniquingKeysWith: +)
        var problems: [String] = []
        for entry in try current() {
            if let count = remaining[entry], count > 0 {
                remaining[entry] = count - 1
            } else {
                problems.append("new SPI, not in spi-surface.txt: \(entry.replacingOccurrences(of: "\t", with: ": ")) (make it public API, or internal, or list it on purpose)")
            }
        }
        for (entry, count) in remaining.sorted(by: { $0.key < $1.key }) where count > 0 {
            problems.append("spi-surface.txt lists \(entry.replacingOccurrences(of: "\t", with: ": ")), which is no longer SPI: remove the line")
        }
        return problems
    }

    private static func writeLedger() throws {
        let header = try String(contentsOf: ledger, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).prefix { $0.hasPrefix("#") }
        try (header.map(String.init) + (try current())).joined(separator: "\n").appending("\n").write(to: ledger, atomically: true, encoding: .utf8)
    }

    private static func dropStaleLines() throws {
        var remaining = Dictionary(try current().map { ($0, 1) }, uniquingKeysWith: +)
        var kept: [Substring] = []
        for line in try String(contentsOf: ledger, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("#") || line.isEmpty { kept.append(line); continue }
            if let count = remaining[String(line)], count > 0 {
                remaining[String(line)] = count - 1
                kept.append(line)
            }
        }
        try kept.joined(separator: "\n").write(to: ledger, atomically: true, encoding: .utf8)
    }
}

/// The public API's top level: the types an embedder meets, and nothing else (Docs/Design/swiit-public-api.md, §3). Each is
/// documented there; a new one is a decision, made by adding its name here and to the design.
enum PublicSurface {
    static let allowed: Set<String> = [
        "Interpreter", "Value", "ValueDictionary", "Callable", "ValueType", "HostObject", "DynamicObject",
        "ValueConvertible", "ScriptEnum", "HostFunction", "Diagnostic", "SourceRange", "OutputSink", "Symbol", "NativeType", "DisplaySegment",
    ]

    private static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Swiit")
    private static let declaration = try! NSRegularExpression(pattern:
        #"^(?:@\w+(?:\([^)]*\))?\s+)*public\s+(?:final\s+|indirect\s+)*(?:class|struct|enum|protocol|typealias|func|var|let)\s+([A-Za-z_]\w*)"#,
        options: [.anchorsMatchLines])

    /// The top-level `public` declarations (not `@_spi`), by name, outside the standard library's target and the generated glue.
    static func current() throws -> Set<String> {
        var names: Set<String> = []
        let files = FileManager.default.enumerator(atPath: sources.path)!.compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") && !$0.hasPrefix("Library/") && !$0.contains("Generated/") }
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for match in declaration.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let line = text[Range(match.range, in: text)!]
                if line.contains("@_spi") { continue }
                names.insert(String(text[Range(match.range(at: 1), in: text)!]))
            }
        }
        return names
    }
}
