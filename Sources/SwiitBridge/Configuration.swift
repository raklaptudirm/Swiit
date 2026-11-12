import Foundation

// What a package says about its bridge, and how the generator reaches the package's symbol graph:
// `swiit-bridge --package <dir> --module <Target> --output <file> [--config <file>]`.

/// `swiit-bridge.json`, beside a package: the settings the flags give, as a file. Each is optional.
struct Configuration: Decodable {
    /// The output declares `<name>Bridge`.
    var name: String?
    /// The access level of what the output declares: `public` (the default) or `internal`.
    var access: String?
    /// The module the output is a file of, which it does not import.
    var inModule: String?
    /// The types to bridge. Without it, those of the module with a public member.
    var types: [String]?
    /// The top-level functions to bridge. Without it, the module's public ones.
    var functions: [String]?
    /// Types another bridge describes, held as they are.
    var boxed: [String]?
    /// Types that convert themselves (`ScriptConvertible`): an enum that is `CaseIterable` does
    /// without being listed.
    var convertible: [String]?
    /// How to find the types and functions of the module that scripts get, when none are named:
    /// `"public"` for a module whose whole public surface is for scripts; by default, the types
    /// that conform to `ScriptConvertible` (for a module that also has an interface for a host
    /// program) and the functions named.
    var discover: String?
    /// Types the module has that scripts do not.
    var skip: [String]?
    /// A member scripts know under another name, as `"Date.shown": "description"`.
    var rename: [String: String]?
    /// Modules the glue names types of, besides the one it bridges.
    var imports: [String]?
}

/// The value after `flag` in `arguments`, and the arguments without the pair.
private func take(_ flag: String, from arguments: inout [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
        return nil
    }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
}

/// The arguments the program reads: `<graph> <output> [flags]`. Given `--package`, the symbol
/// graph is the package's, which the generator makes itself: the glue it is about to write is
/// part of that module, so a stub stands in for it while the module builds.
func preparedArguments() throws -> [String] {
    var arguments = CommandLine.arguments
    guard let package = take("--package", from: &arguments) else { return arguments }
    guard let module = take("--module", from: &arguments),
        let output = take("--output", from: &arguments)
    else {
        throw Failure("--package needs --module and --output")
    }
    let configuration = try arguments.firstIndex(of: "--config")
        .flatMap { index in
            index + 1 < arguments.count ? arguments[index + 1] : nil
        }
        .map {
            try JSONDecoder()
                .decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: $0)))
        }
    let name = configuration?.name ?? arguments.firstIndex(of: "--name").map { arguments[$0 + 1] }
    let level =
        arguments.firstIndex(of: "--access").map { arguments[$0 + 1] }
        ?? configuration?.access ?? "public"
    let inModule =
        arguments.firstIndex(of: "--in-module").map { arguments[$0 + 1] }
        ?? configuration?.inModule

    try """
    \(inModule == "Swiit" ? "" : "import Swiit\n")
    \(level) enum \(name ?? "Generated")Bridge {
        \(level) static let types: [HostType] = []
        \(level) static let functions: [HostSymbol] = []
    }

    """
    .write(toFile: output, atomically: true, encoding: .utf8)

    let directory = try symbolGraphs(
        of: package,
        minimumAccess: level == "public" ? "public" : "internal"
    )
    let graph = "\(directory)/\(module).symbols.json"
    let extensions = try FileManager.default.contentsOfDirectory(atPath: directory)
        .filter { $0.hasPrefix("\(module)@") && $0.hasSuffix(".symbols.json") }
        .sorted()
        .map { "\(directory)/\($0)" }
    return [arguments[0], graph, output] + arguments.dropFirst() + extensions
}

/// Writes the symbol graphs of a package's targets with SwiftPM, and gives the directory.
private func symbolGraphs(of package: String, minimumAccess: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "swift", "package", "--package-path", package, "dump-symbol-graph",
        "--minimum-access-level", minimumAccess, "--skip-synthesized-members",
    ]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw Failure("the package did not build:\n\(output)")
    }
    let prefix = "Files written to "
    guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix(prefix) }) else {
        throw Failure("swift package gave no symbol graph directory:\n\(output)")
    }
    return String(line.dropFirst(prefix.count))
}

/// Something the generator was asked for that it cannot do.
struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: Reading the settings

extension Configuration {
    /// The settings in the file named by `--config`, if there is one.
    static func read(_ path: String) throws -> Configuration {
        try JSONDecoder()
            .decode(
                Configuration.self,
                from: Data(contentsOf: URL(fileURLWithPath: path))
            )
    }
}

// MARK: Finding what to bridge

/// The protocols a symbol conforms to, whatever it declares, and those they inherit from.
private func allConformances(in graph: Graph) -> [String: Set<String>] {
    let byID = Dictionary(
        graph.symbols.map { ($0.identifier.precise, $0) },
        uniquingKeysWith: { first, _ in first }
    )
    func name(_ relationship: Relationship) -> String {
        relationship.targetFallback.map { String($0.split(separator: ".").last!) }
            ?? byID[relationship.target]?.pathComponents.last ?? ""
    }
    var direct: [String: Set<String>] = [:]
    var inherited: [String: Set<String>] = [:]
    for relationship in graph.relationships {
        guard let source = byID[relationship.source]?.pathComponents.last else { continue }
        switch relationship.kind {
        case "conformsTo": direct[source, default: []].insert(name(relationship))
        case "inheritsFrom": inherited[source, default: []].insert(name(relationship))
        default: break
        }
    }
    func closure(_ protocolName: String, seen: inout Set<String>) {
        guard seen.insert(protocolName).inserted else { return }
        for parent in inherited[protocolName] ?? [] { closure(parent, seen: &seen) }
    }
    return direct.mapValues { protocols in
        var all: Set<String> = []
        for protocolName in protocols { closure(protocolName, seen: &all) }
        return all
    }
}

/// The types of the module that scripts get: each struct or enum it defines that has a public
/// member and, unless the module's public surface is all for scripts (`byAccess`), is
/// `ScriptConvertible` (which a type says by conforming, itself or through a protocol it
/// refines); less those the settings skip, and the enums that convert themselves.
func discoveredTypes(
    in graph: Graph,
    skipping skipped: Set<String>,
    byAccess: Bool = false
) -> [String] {
    let conformances = allConformances(in: graph)
    let withPublicMembers = Set(
        graph.symbols.filter { $0.pathComponents.count == 2 && $0.accessLevel == "public" }
            .map { $0.pathComponents[0] }
    )
    return graph.symbols
        .filter {
            $0.pathComponents.count == 1
                && ["swift.struct", "swift.enum"].contains($0.kind.identifier)
        }
        .map { $0.pathComponents[0] }
        .filter {
            withPublicMembers.contains($0) && !skipped.contains($0)
                && (byAccess || conformances[$0]?.contains("ScriptConvertible") == true)
        }
        .sorted()
}

/// The enums of the module that are `CaseIterable` and `ScriptConvertible`: scripts get them as
/// the enums they are.
func selfConvertingEnums(in graph: Graph) -> [String] {
    let conformances = allConformances(in: graph)
    return graph.symbols
        .filter { $0.kind.identifier == "swift.enum" && $0.pathComponents.count == 1 }
        .map { $0.pathComponents[0] }
        .filter { conformances[$0]?.isSuperset(of: ["CaseIterable", "ScriptConvertible"]) == true }
}

/// The names of the module's public top-level functions.
func discoveredFunctions(in graph: Graph, skipping skipped: Set<String>) -> [String] {
    var names: [String] = []
    for symbol in graph.symbols
    where symbol.kind.identifier == "swift.func" && symbol.pathComponents.count == 1
        && symbol.accessLevel == "public"
    {
        let name = String(symbol.pathComponents[0].prefix { $0 != "(" })
        if !names.contains(name) && !skipped.contains(name) { names.append(name) }
    }
    return names
}
