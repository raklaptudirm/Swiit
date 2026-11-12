// Reads a Swift module's symbol graph and writes the Swift that bridges
// its types' members to Swiit: each member's signature, for the checker,
// and glue that converts Swiit values, calls Swift and converts back.
//
//   swiit-bridge <Module.symbols.json> <output.swift> [<Other@Module.symbols.json>...]
//                [--manifest <platform.json>] [--also <other-platform.json>...]
//                [--report <left-out.tsv>] --name <Name> --type <Type>... [--access <level>]
//                [--in-module <Module>]
//
// The output is a description of the types, `HostType` and `HostSymbol`, which compiles in any
// package that imports Swiit. `--type` names each type to bridge (`Dictionary`,
// `FilePath.Component`), and the graph says what it is generic over. `--name` names the output's
// enum (`<Name>Bridge`), and `--access` is the access level of what it declares (`public`, the
// default, or `internal`). `--in-module` is the module the output is a file of, which it does not
// import (`Swiit` for Swiit's own files). A member is bridged if it is declared `public`,
// whatever the access of its type.
//
// Scripts/bridge runs it on the standard library, on swift-system
// (for FilePath) and on Foundation; a client with a library of its own
// runs it on that. A member is bridged only if every
// type in its signature is one Swiit can pass or hold (see `supported`); the
// rest are left out, and counted on stderr.
//
// The pieces: SymbolGraph reads the graph; SwiftTypes and Declarations parse
// a declaration's text; Bridging says what Swiit can hold, and Conversions
// how a value crosses; Members makes one member's glue; ModuleTypes reads a
// module's own structs and enums. This file is the program that uses them.
import Foundation

// MARK: Main

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(
        Data(
            "usage: swiit-bridge <Module.symbols.json> <output.swift> [<Other@Module.symbols.json>...] [--manifest <file>] [--also <file>...] [--report <file>] --name <Name> --type <Type>... [--access <level>] [--in-module <Module>]\n"
                .utf8
        )
    )
    exit(2)
}
/// After the output: the graphs of other modules that add to this one's
/// types; `--manifest <file>`, where to write what this platform has; and
/// `--also <file>`, another platform's, so that only what both have is bridged.
nonisolated(unsafe) var extraGraphs: [String] = []  // safe: the generator runs on one thread
nonisolated(unsafe) var manifestPath: String?  // safe: the generator runs on one thread
nonisolated(unsafe) var otherPlatformPaths: [String] = []  // safe: the generator runs on one thread
/// `--report <file>`: where to write each member left out, with the reason it was.
nonisolated(unsafe) var reportPath: String?  // safe: the generator runs on one thread
/// `--name <Name>`: the output declares `<Name>Bridge`.
nonisolated(unsafe) var bridgeName: String?  // safe: the generator runs on one thread
/// `--type <Type>`: the types to bridge, by the name the module gives them.
nonisolated(unsafe) var typeNames: [String] = []  // safe: the generator runs on one thread
/// `--access <level>`: the access level of what the output declares.
nonisolated(unsafe) var access = "public"  // safe: the generator runs on one thread
/// `--in-module <Module>`: the module the output is a file of, if it is one of a module's own.
nonisolated(unsafe) var outputModule: String?  // safe: the generator runs on one thread
do {
    let rest = Array(arguments.dropFirst(3))
    var i = 0
    while i < rest.count {
        switch rest[i] {
        case "--manifest" where i + 1 < rest.count: manifestPath = rest[i + 1]; i += 2
        case "--also" where i + 1 < rest.count: otherPlatformPaths.append(rest[i + 1]); i += 2
        case "--report" where i + 1 < rest.count: reportPath = rest[i + 1]; i += 2
        case "--name" where i + 1 < rest.count: bridgeName = rest[i + 1]; i += 2
        case "--type" where i + 1 < rest.count: typeNames.append(rest[i + 1]); i += 2
        case "--access" where i + 1 < rest.count: access = rest[i + 1]; i += 2
        case "--in-module" where i + 1 < rest.count: outputModule = rest[i + 1]; i += 2
        default: extraGraphs.append(rest[i]); i += 1
        }
    }
}
/// What the other platforms declare, by module: a member is bridged only if
/// every one of them has it.
let otherPlatforms: [Set<String>] = try otherPlatformPaths.map {
    Set(try Manifest(contentsOf: $0).members)
}
/// What this platform declares, whatever the others have and whatever the
/// generator can make of it.
nonisolated(unsafe) var thisPlatform: Set<String> = []  // safe: the generator runs on one thread
func readGraph(_ path: String) throws -> Graph {
    try JSONDecoder().decode(Graph.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
}
/// The module's graph, with what other modules add to its types and
/// protocols (`_StringProcessing`'s `contains(_:)` on Collection).
nonisolated(unsafe) var addedByOthers: Set<String> = []  // safe: the generator runs on one thread
nonisolated(unsafe) var extraModules: [String] = []  // safe: the generator runs on one thread
let graph: Graph = try {
    var graph = try readGraph(arguments[1])
    for path in extraGraphs {
        let extra = try readGraph(path)
        if !extraModules.contains(extra.module.name) { extraModules.append(extra.module.name) }
        addedByOthers.formUnion(extra.symbols.map(\.identifier.precise))
        graph = Graph(
            module: graph.module,
            symbols: graph.symbols + extra.symbols,
            relationships: graph.relationships + extra.relationships
        )
    }
    return graph
}()

guard let bridgeName, !typeNames.isEmpty else {
    FileHandle.standardError.write(
        Data("swiit-bridge: --name and at least one --type are needed\n".utf8)
    )
    exit(2)
}
/// The types to bridge, with the generic parameters the graph gives each.
let bridgedTypeNames: [(String, [String])] = try typeNames.map { name in
    let path = name.split(separator: ".").map(String.init)
    guard
        let symbol = graph.symbols.first(where: {
            $0.pathComponents == path
                && ($0.kind.identifier == "swift.struct" || $0.kind.identifier == "swift.enum")
        })
    else {
        FileHandle.standardError.write(
            Data("swiit-bridge: \(graph.module.name) has no struct or enum \(name)\n".utf8)
        )
        exit(2)
    }
    return (name, symbol.swiftGenerics?.parameters?.map(\.name) ?? [])
}
for symbol in graph.symbols
where symbol.kind.identifier == "swift.typealias" && symbol.pathComponents.count == 1 {
    let text = (symbol.declarationFragments ?? []).map(\.spelling).joined()
    guard let equals = text.range(of: "=") else { continue }
    var reader = Reader(String(text[equals.upperBound...]))
    if let target = try? reader.type() { topLevelAliases[symbol.pathComponents[0]] = target }
}
// Other types that aren't generic, Swiit having no value of its own for
// them (Character, FilePath), are held as they are, boxed.
for (name, parameters) in bridgedTypeNames where parameters.isEmpty && leaves[name] == nil {
    leaves[name] = boxedLeaf(name)
}
/// Members Swiit has its own way: the textual form of the types it
/// formats, and a dictionary's keys and values, which are arrays rather
/// than Swift's views.
let swiitOwn: [String: Set<String>] = [
    "Array": ["description", "debugDescription"],
    "Optional": ["description", "debugDescription"],
    "Dictionary": ["description", "debugDescription", "keys", "values"],
]

var typeIDs: [[String]: String] = [:]
for symbol in graph.symbols
where symbol.kind.identifier == "swift.struct" || symbol.kind.identifier == "swift.enum" {
    typeIDs[symbol.pathComponents] = symbol.identifier.precise
}
let symbolsByID = Dictionary(
    graph.symbols.map { ($0.identifier.precise, $0) },
    uniquingKeysWith: { first, _ in first }
)

/// The protocols the module declares: where their members are listed.
let protocolNames = Set(
    graph.symbols.filter { $0.kind.identifier == "swift.protocol" }.map(\.pathComponents[0])
)

nonisolated(unsafe) var types: [String: BridgedType] = [:]  // safe: the generator runs on one thread
for (name, parameters) in bridgedTypeNames {
    var type = BridgedType(name: name, parameters: parameters)
    let path = name.split(separator: ".").map(String.init)
    for symbol in graph.symbols
    where symbol.pathComponents.dropLast() == path[...]
        && symbol.kind.identifier == "swift.typealias"
    {
        let text = (symbol.declarationFragments ?? []).map(\.spelling).joined()
        guard let equals = text.range(of: "=") else { continue }
        var reader = Reader(String(text[equals.upperBound...]))
        if let target = try? reader.type() { type.associated[symbol.pathComponents.last!] = target }
    }
    types[name] = type
}
for (name, _) in bridgedTypeNames {
    var type = types[name]!
    let id = typeIDs[name.split(separator: ".").map(String.init)]
    for relationship in graph.relationships
    where relationship.kind == "conformsTo" && relationship.source == id {
        var proto =
            relationship.targetFallback.map { String($0.split(separator: ".").last!) }
            ?? symbolsByID[relationship.target]?.pathComponents.last ?? ""
        type.allConformances.insert(proto)
        if proto == "Collection" || proto == "BidirectionalCollection" { proto = "Sequence" }
        guard knownProtocols.contains(proto) else { continue }
        // What the generic parameters must be for it, if Swiit can say.
        var needs: [String: [String]] = [:]
        var sayable = true
        for constraint in relationship.swiftConstraints ?? []
        where !alwaysMet.contains(constraint.rhs) {
            if strideFix(constraint) { needs["Bound"] = ["=Int"]; continue }
            if constraint.lhs.contains(".") { continue }  // Bound.Stride, with Bound an Int
            if valueProtocols.contains(constraint.rhs) || constraint.rhs == "Encodable" {
                if needs[constraint.lhs] != ["=Int"] {
                    needs[constraint.lhs, default: []].append(constraint.rhs)
                }
            } else {
                sayable = false
            }
        }
        guard sayable else { continue }
        // Of a conformance declared more than once, the least demanding.
        if let existing = type.conformances[proto],
            existing.values.map(\.count).reduce(0, +) <= needs.values.map(\.count).reduce(0, +)
        {
            continue
        }
        type.conformances[proto] = needs.mapValues { Array(Set($0)).sorted() }
    }
    types[name] = type
}

/// The modules the output imports: the one it bridges (unless the output is a file of it, or it
/// is the standard library) and those that add to its types.
let moduleImports =
    ((graph.module.name == "Swift" || graph.module.name == outputModule ? [] : [graph.module.name])
    + extraModules)
    .map { "import \($0)\n" }.joined()
var output = """
    // swift-format-ignore-file
    // Generated by swiit-bridge from the \(graph.module.name) module's symbol graph.
    // Don't edit: the bridge generator (swiit-bridge) remakes it.
    import Foundation
    \(moduleImports)
    \(outputModule == "Swiit" ? "" : "import Swiit\n")
    \(access) enum \(bridgeName)Bridge {
        \(access) static let types: [HostType] = [


    """
var skipped: [String: Int] = [:]
/// Each member the generator could not bridge, as `reason`, the type it is of and its name, for
/// `--report`. (A reason names what was unsupported, so the same kind of gap groups together.)
struct LeftOut {
    let reason: String
    let owner: String
    let member: String
}
nonisolated(unsafe) var leftOut: [LeftOut] = []  // safe: the generator runs on one thread
var counts: [String: Int] = [:]
/// Each member is a declaration of its own, not an element of one big
/// array: Swift checks an expression at a time, and 80 closures in a literal
/// take gigabytes to check together.
nonisolated(unsafe) var declarations: [String] = []  // safe: the generator runs on one thread
func declare(_ expression: String) -> String {
    let name = "member\(declarations.count)"
    declarations.append(
        "    private static let \(name): HostSymbol = \(expression)\n"
    )
    return name
}

for (name, _) in bridgedTypeNames {
    // A type of another module is known to the generator as it is: what is made is only what this
    // module adds to it.
    let owner = types[name] ?? BridgedType(name: name, parameters: [])
    var seen: Set<String> = []
    var members: [String] = []
    let kinds = [
        "swift.method", "swift.property", "swift.init", "swift.type.method", "swift.type.property",
        "swift.func.op",
    ]
    // Its own members, then those of the protocols it conforms to, whether
    // required or added by an extension (`Collection.contains`,
    // `Sequence.max`), which the graph lists under the protocol, not the
    // type. The type's own member of the same name and labels hides the
    // protocol's, as in Swift (`Set.union(_: Sequence)` over
    // `SetAlgebra.union(_: Self)`); if it can't be bridged, the protocol's is
    // what there is (String's `reversed` gives a ReversedCollection, which
    // Swiit has no value for, but Sequence's gives an array).
    let path = name.split(separator: ".").map(String.init)
    // A declaration written in terms of `Self` is a protocol's, which a newer graph lists under the
    // type too; the type's own, of the same shape, comes first and is the one that is kept.
    let ownSymbols = graph.symbols.filter { $0.pathComponents.dropLast() == path[...] }
        .partitioned(by: { symbol in
            !(symbol.declarationFragments ?? []).map(\.spelling).joined().contains("Self.")
        })
    var candidates = ownSymbols.map { ($0, [Constraint]()) }
    // A range is a sequence only when `Bound: Strideable` with a
    // SignedInteger stride: for Swiit, when Bound is Int.
    let conditions =
        name == "Range" || name == "ClosedRange"
        ? [
            Constraint(kind: "conformance", lhs: "Bound", rhs: "Strideable"),
            Constraint(kind: "conformance", lhs: "Bound.Stride", rhs: "SignedInteger"),
        ]
        : []
    candidates += graph.symbols
        .filter {
            // Not initializers: a protocol's is a requirement the type meets
            // with its own, which isn't the same call.
            $0.pathComponents.count == 2 && protocolNames.contains($0.pathComponents[0])
                && $0.kind.identifier != "swift.init"
                && owner.allConformances.contains($0.pathComponents[0])
        }
        .map { ($0, conditions) }
    var bridgedShapes: Set<String> = []
    let ownCount = ownSymbols.count
    for (index, (symbol, conditions)) in candidates.enumerated() {
        guard kinds.contains(symbol.kind.identifier), symbol.accessLevel == "public",
            available(symbol)
        else {
            continue
        }
        let title = symbol.pathComponents.last!
        // Operators of a type from another module: the standard library's
        // (Int, String…) are the host's own, which doesn't ask Swift.
        let isOperator = symbol.kind.identifier == "swift.func.op"
        guard !title.hasPrefix("_"),
            title.first?.isLetter ?? false || isOperator && graph.module.name != "Swift"
        else {
            continue
        }
        // The interpreter's own, which a host does not call.
        if title.hasPrefix("swiit") { continue }
        if isOperator && graph.module.name == "Swift" { continue }
        if swiitOwn[name]?.contains(title) ?? false { continue }
        // What this platform declares, whether or not the generator can bridge
        // it (a graph's shape differs by platform, and so does what can be made
        // of it, but a name and its labels are the same); and what's bridged
        // is what all of them declare.
        let declared = "\(name)\t\(symbol.kind.identifier)\t\(title)"
        thisPlatform.insert(declared)
        guard otherPlatforms.allSatisfy({ $0.contains(declared) }) else {
            skipped["other-platform", default: 0] += 1
            continue
        }
        do {
            let bridged = try bridge(symbol, of: owner, given: conditions)
            let (key, shape) = (bridged.key, bridged.shape)
            // What another module adds is an overload, not a default.
            if index >= ownCount, bridgedShapes.contains(shape),
                !addedByOthers.contains(symbol.identifier.precise)
            {
                continue
            }
            guard seen.insert(key).inserted else { continue }
            if index < ownCount { bridgedShapes.insert(shape) }
            members.append(declare(bridged.code))
            counts[name, default: 0] += 1
        } catch let unsupported as Unsupported {
            // SWIIT_BRIDGE_DEBUG=Set: why each of a type's members is left out.
            if ProcessInfo.processInfo.environment["SWIIT_BRIDGE_DEBUG"] == name {
                FileHandle.standardError.write(Data("\(title): \(unsupported.reason)\n".utf8))
            }
            skipped[
                unsupported.reason.split(separator: " ").first.map(String.init) ?? "?",
                default: 0
            ] += 1
            leftOut.append(LeftOut(reason: unsupported.reason, owner: name, member: title))
        }
    }
    let context = Context(owner: owner, generics: Set(owner.genericParameters))
    // Text as one of these, from the type's own declarations. `parse`: a
    // failable initializer from text, which can say no (Int, Bool, Double).
    // `literal`: Swift's rules for text literals (String, Character,
    // FilePath), picked by the most specific literal protocol it conforms to.
    var parse = "nil"
    var literal = "nil"
    // `arrayLiteral`: items as one, for a generic collection an array
    // literal can be (Array, Set, ArraySlice), through its initializer from
    // any sequence: what several words for one parameter become.
    var arrayLiteral = "nil"
    if owner.parameters.count == 1, owner.allConformances.contains("ExpressibleByArrayLiteral"),
        graph.symbols.contains(where: {
            $0.pathComponents == [name, $0.pathComponents.last!]
                && $0.kind.identifier == "swift.init" && available($0) && isSequenceInitializer($0)
        })
    {
        let collection = selfType(owner)
        arrayLiteral = "{ \(toValue("\(spelling(collection))($0)", collection)) }"
    }
    if owner.parameters.isEmpty {
        let selfType = SType.named(name, [])
        if graph.symbols.contains(where: {
            $0.pathComponents == name.split(separator: ".").map(String.init) + [
                $0.pathComponents.last!
            ]
                && $0.kind.identifier == "swift.init" && available($0) && isTextInitializer($0)
        }) {
            parse = "{ \(name)($0).map { \(toValue("$0", selfType)) } }"
        }
        if owner.allConformances.contains("ExpressibleByUnicodeScalarLiteral") {
            literal =
                "{ Value.Bridging.textLiteral(\(name).self, $0).map { \(toValue("$0", selfType)) } }"
        }
    }
    do {
        let typeName = "type\(declarations.count)"
        let associatedTypes = owner.associated
            .compactMap { key, value -> String? in
                guard let resolved = resolve(value, context),
                    supported(resolved, generics: context.generics, asParameter: false)
                else { return nil }
                return "\(quoted(key)): \(scriptType(resolved))"
            }
            .sorted()
        let conformanceCode = owner.conformances.sorted { $0.key < $1.key }
            .map { "\(quoted($0)): \(genericParametersDescription($1))" }
        declarations.append(
            """
                private static let \(typeName): HostType = {
                    var type = HostType(name: \(quoted(name)), members: [\(members.joined(separator: ", "))])
                    type.genericParameters = [\(owner.parameters.map(quoted).joined(separator: ", "))]
                    type.conformances = [\(conformanceCode.isEmpty ? ":" : conformanceCode.joined(separator: ", "))]
                    type.associatedTypes = [\(associatedTypes.isEmpty ? ":" : associatedTypes.joined(separator: ", "))]
                    type.parse = \(parse)
                    type.literal = \(literal)
                    type.arrayLiteral = \(arrayLiteral)
                    return type
                }()

            """
        )
        output += "        \(typeName),\n"
    }
}
output += "    ]\n"
output += declarations.joined(separator: "\n") + "}\n"
try output.write(to: URL(fileURLWithPath: arguments[2]), atomically: true, encoding: .utf8)
if let manifestPath {
    try Manifest(
        platform: Manifest.current,
        module: graph.module.name,
        members: thisPlatform.sorted()
    )
    .write(to: manifestPath)
}
if let reportPath {
    let lines =
        leftOut.sorted { ($0.reason, $0.owner, $0.member) < ($1.reason, $1.owner, $1.member) }
        .map { line -> String in
            let kind = line.reason.split(separator: " ").first.map(String.init) ?? "?"
            return "\(kind)\t\(line.reason)\t\(line.owner)\t\(line.member)"
        }
    try (["kind\treason\ttype\tmember"] + lines).joined(separator: "\n")
        .appending("\n").write(toFile: reportPath, atomically: true, encoding: .utf8)
}
let total = counts.values.reduce(0, +)
FileHandle.standardError.write(
    Data(
        "bridged \(total) members (\(bridgedTypeNames.map { "\($0.0) \(counts[$0.0] ?? 0)" }.joined(separator: ", "))); left out: \(skipped.sorted { $0.value > $1.value }.prefix(12).map { "\($0.key) \($0.value)" }.joined(separator: ", "))\n"
            .utf8
    )
)

extension Array {
    /// The elements that satisfy `predicate`, then the rest, each in their order.
    func partitioned(by predicate: (Element) -> Bool) -> [Element] {
        filter(predicate) + filter { !predicate($0) }
    }
}
