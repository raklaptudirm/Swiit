import Foundation
import Swiit

/// Checks the files headed for the embeddable core against the boundary
/// rules (Docs/boundaries.md). A support file because it reads source
/// with Foundation, which the test file can't import beside Testing.
enum Boundaries {
    /// The directories of `Sources/Swiit` that stay in the core, with everything under them.
    static let coreDirectories = [
        "Language", "HostInterface", "SwiftLibraryBridges/HandWritten", "Model/Symbols",
        "Model/Diagnostics",
    ]

    /// The one place the core makes a thread: a run goes on a large stack,
    /// so deep recursion needs no setup from the embedder (embedding.md, step 5). And the two that
    /// keep a run's state in the thread it is on (`Thread.current`), which makes no thread and
    /// reaches nothing of the system.
    static let permitted: [String: Set<String>] = [
        "HostInterface/LargeStack.swift": ["Thread", "DispatchSemaphore", "signal("],
        "HostInterface/Registration/Context.swift": ["Thread"],
        "HostInterface/Registration/Waiting.swift": ["Thread"],
    ]

    /// The shell's concepts, by the group the ledger counts them under.
    static let groups: [(name: String, pattern: String)] = [
        (
            "grammar",
            #"\b(PipelineNode|CommandNode|StageResolution|StageReceiver|Redirect|ResolvedRedirect)\b|\.pipeline\b"#
        ),
        ("chain", #"\b(Chain|Unit)\b"#),
        ("env", #"\b(environmentAccess|isEnvironment|environmentRecord)\b|\.environment\b"#),
        ("jobs", #"\b(Job|jobs)\b"#),
        ("layer", #"\b(shellLayer|commandAccess)\b"#),
        ("shell", #"(?<!_spi\()\bShell\b"#),
        ("status", #"\b(lastStatus|lastSignalStatus)\b"#),
        ("file", #"\b(scriptPath|scriptDirectory)\b"#),
        ("history", #"\bhistoryEntries\b"#),
        // What a command line is made of: flags, and what is piped in.
        ("commandline", #"\b(isInput|shortFlag|inputParameter)\b|@input\b|@flag\b"#),
        // What a command gives back, and the files it lists.
        ("results", #"\b(Output|Status|FileEntry|FileType)\b"#),
        // How a terminal shows values: color, styles, tables.
        ("display", #"\b(colorOutput|TextStyle|Tabular|DisplayColumn|DisplayRegistry)\b"#),
        (
            "commands",
            #"\b(shellBuiltins|findExecutable|commandFunctions|callCommand)\b|\bcommandLine\w*"#
        ),
    ]

    /// The operating system, which the core reaches only through `Interpreter.Host`.
    static let operatingSystem =
        #"\b(stdoutFD|stderrFD|STDIN_FILENO|STDOUT_FILENO|STDERR_FILENO|writeAll|getenv|setenv|unsetenv|isatty|ioctl|termios|waitpid|posix_spawn|fork|execv|execvp|kill|sigaction|ProcessInfo|FileManager|dlopen|dlsym|getpgrp|tcsetpgrp|chdir|getcwd|currentDirectoryPath|takeInterruptSignal|takeInterrupt|FileHandle|DispatchSemaphore|DispatchQueue|Thread)\b|\benv\(|\bsignal\(|\bpipe\(|\bProcess\("#

    private static let here = URL(fileURLWithPath: #filePath)
    private static let sources = here.deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/Swiit")
    private static let ledger = here.deletingLastPathComponent()
        .appendingPathComponent("boundaries.txt")

    /// What's wrong, one line each; empty when the core is inside its boundaries.
    static func violations() throws -> [String] {
        var allowed: [String: Int] = [:]  // "file\tgroup" to count
        for line in try String(contentsOf: ledger, encoding: .utf8).split(separator: "\n")
        where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t").map(String.init)
            if fields.count == 4, fields[0] == "allow", let count = Int(fields[3]) {
                allowed["\(fields[1])\t\(fields[2])"] = count
            } else {
                return ["boundaries.txt: can't read the line \(line)"]
            }
        }

        var problems: [String] = []
        var seen: Set<String> = []
        for directory in coreDirectories {
            let root = sources.appendingPathComponent(directory)
            // Every file under the directory, however deep: a folder added later is checked too.
            for relative in FileManager.default.enumerator(atPath: root.path)!
                .compactMap({ $0 as? String }).filter({ $0.hasSuffix(".swift") }).sorted()
            {
                let file = "\(directory)/\(relative)"
                seen.insert(file)
                let source = code(
                    of: try String(
                        contentsOf: root.appendingPathComponent(relative),
                        encoding: .utf8
                    )
                )

                let reached = matches(operatingSystem, in: source)
                    .filter { !(permitted[file]?.contains($0) ?? false) }
                if !reached.isEmpty {
                    problems.append(
                        "\(file): reaches the operating system directly (\(Set(reached).sorted().joined(separator: ", "))); go through Interpreter.Host"
                    )
                }
                for (group, pattern) in groups {
                    let count = matches(pattern, in: source).count
                    let allowance = allowed["\(file)\t\(group)"] ?? 0
                    if count > allowance {
                        problems.append(
                            "\(file): \(count) uses of the shell's \(group) concepts, the ledger allows \(allowance): a new dependency; see boundaries.md"
                        )
                    } else if count < allowance {
                        problems.append(
                            "\(file): \(count) uses of the shell's \(group) concepts, the ledger says \(allowance): an exit was reached, so lower it in boundaries.txt"
                        )
                    }
                }
            }
        }
        for key in allowed.keys.sorted() {
            let file = String(key.split(separator: "\t")[0])
            if !seen.contains(file) {
                problems.append(
                    "boundaries.txt: allows \(file), which isn't in the core directories any more"
                )
            }
        }
        return problems
    }

    /// Source without comments, which may say anything.
    private static func code(of source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { line -> String? in
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { return nil }
                return line.replacingOccurrences(
                    of: #"\s//.*$"#,
                    with: "",
                    options: .regularExpression
                )
            }
            .joined(separator: "\n")
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        let expression = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range)
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
}

/// What a host's output sinks write to, in tests: the sinks are `Sendable`.
final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    var text: String { lock.withLock { value } }
    func add(_ more: String) { lock.withLock { value += more } }
    var sink: OutputSink {
        OutputSink { [self] in
            add($0); return true
        }
    }
}
