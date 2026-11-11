import Foundation

/// Which layers a lower layer may name (Docs/boundaries.md). The folders under `Sources/Swiit` are
/// layers, and a layer names only the ones below it: what is shared by all of them is `Model`, the
/// tree is built on it, and so on up to the host's interface. A support file because it reads
/// source with Foundation, which the test file can't import beside Testing.
enum Layering {
    /// A layer's folder, and the folders whose declarations it may name, besides its own.
    static let rules: [(layer: String, mayName: [String])] = [
        ("Model", []),
        ("Language/SyntaxTree", ["Model"]),
    ]

    private static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/Swiit")

    private static let declaration = try! NSRegularExpression(
        pattern:
            #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|private|fileprivate|final|indirect)\s+)*(?:struct|class|enum|protocol|actor|typealias)\s+([A-Z]\w*)"#,
        options: [.anchorsMatchLines]
    )

    /// What is wrong, one line each; empty when no layer names one above it.
    static func violations() throws -> [String] {
        let files = FileManager.default.enumerator(atPath: sources.path)!
            .compactMap { $0 as? String }
            .filter {
                $0.hasSuffix(".swift") && !$0.contains("Generated/")
                    // The prelude is Swift written for the interpreter to read: its declarations
                    // (Error, Mirror, Void) are not types of this module.
                    && $0 != "Language/Builtins/Prelude.swift"
            }
            .sorted()

        func layer(of file: String) -> String {
            let parts = file.split(separator: "/").map(String.init)
            return parts[0] == "Language" ? "\(parts[0])/\(parts[1])" : parts[0]
        }

        var text: [String: String] = [:]
        var declaredIn: [String: Set<String>] = [:]  // name to the layers that declare it
        for file in files {
            let source = try String(
                contentsOf: sources.appendingPathComponent(file),
                encoding: .utf8
            )
            let code = source.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            text[file] = code
            for match in declaration.matches(
                in: code,
                range: NSRange(code.startIndex..., in: code)
            ) {
                let name = String(code[Range(match.range(at: 1), in: code)!])
                declaredIn[name, default: []].insert(layer(of: file))
            }
        }

        var problems: [String] = []
        for (layer, mayName) in rules {
            let allowed = Set(mayName + [layer])
            // A name declared in an allowed layer too (a nested `Symbol.Function` beside a top-level
            // `Function` elsewhere) cannot be told apart, so it is not counted.
            let forbidden = declaredIn.filter { _, layers in
                !layers.isEmpty && layers.isDisjoint(with: allowed)
            }
            for file in files where self.layer(of: file) == layer {
                let code = text[file]!
                for (name, layers) in forbidden.sorted(by: { $0.key < $1.key })
                where code.range(of: #"\b\#(name)\b"#, options: .regularExpression) != nil {
                    problems.append(
                        "\(file): names \(name), which is in \(layers.sorted().joined(separator: ", ")), above \(layer)"
                    )
                }
            }
        }
        return problems
    }

    private static func layer(of file: String) -> String {
        let parts = file.split(separator: "/").map(String.init)
        return parts[0] == "Language" ? "\(parts[0])/\(parts[1])" : parts[0]
    }
}
