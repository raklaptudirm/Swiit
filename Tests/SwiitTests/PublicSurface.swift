import Foundation


/// The public API's top level: the types an embedder meets, and nothing else (Docs/Design/swiit-public-api.md, §3). Each is
/// documented there; a new one is a decision, made by adding its name here and to the design.
enum PublicSurface {
    static let allowed: Set<String> = [
        "Interpreter", "Value", "ValueDictionary", "Callable", "ValueType", "HostObject", "DynamicObject",
        "ValueConvertible", "ScriptEnum", "HostFunction", "Diagnostic", "SourceRange", "OutputSink", "Symbol", "NativeType", "DisplaySegment", "ScriptError", "Unwinding", "Cancellation", "TypeDescription", "TaskHandle", "Awaiting", "Record", "EnumValue", "EnumType", "Flow", "DisplayStyle", "DisplayStyleAttribute", "StandsForText", "SwiitDisplayed",
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
                names.insert(String(text[Range(match.range(at: 1), in: text)!]))
            }
        }
        return names
    }
}
