import Foundation

/// The core's SPI: what it lets its own layers (the shell, the SwiftSyntax
/// front end) use without making it public API. Each declaration is listed in
/// spi-surface.txt, so a new one is a decision, and the list only shrinks as
/// they become public API or internal (Docs/Design/extraction.md, stage 1).
enum SPISurface {
    private static let here = URL(fileURLWithPath: #filePath)
    private static let sources = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Swiit")
    static let ledger = here.deletingLastPathComponent().appendingPathComponent("spi-surface.txt")

    private static let declaration = try! NSRegularExpression(pattern:
        #"@_spi\(Shell\)\s+public\s+(?:(?:static|final|indirect|mutating|nonisolated\(unsafe\)|override|convenience|required|lazy|weak|unowned)\s+)*(func|var|let|init|class|struct|enum|protocol|typealias|case|subscript)\b\s*([A-Za-z_][A-Za-z0-9_]*|[^\s(<:]+)?"#)

    /// Each SPI declaration, as `file<TAB>kind name`, in order.
    static func current() throws -> [String] {
        var entries: [String] = []
        let files = FileManager.default.enumerator(atPath: sources.path)!.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }
        for file in files.sorted() {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for match in declaration.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let kind = String(text[Range(match.range(at: 1), in: text)!])
                let name = Range(match.range(at: 2), in: text).map { String(text[$0]) } ?? kind
                entries.append("\(file)\t\(kind) \(kind == "init" || kind == "subscript" ? kind : name)")
            }
        }
        return entries.sorted()
    }

    /// What differs from the ledger, one line each; empty when they agree.
    static func differences() throws -> [String] {
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
}
