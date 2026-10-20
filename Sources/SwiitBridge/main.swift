// Reads a Swift module's symbol graph and writes the Swift that bridges
// its types' members to Swiit: each member's signature, for the checker,
// and glue that converts Swiit values, calls Swift and converts back.
//
//   swiit-bridge <Module.symbols.json> <output.swift> [<Other@Module.symbols.json>...]
//                [--manifest <platform.json>] [--also <other-platform.json>...]
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
    FileHandle.standardError.write(Data("usage: swiit-bridge <Module.symbols.json> <output.swift> [<Other@Module.symbols.json>...] [--manifest <file>] [--also <file>...]\n".utf8))
    exit(2)
}
/// After the output: the graphs of other modules that add to this one's
/// types; `--manifest <file>`, where to write what this platform has; and
/// `--also <file>`, another platform's, so that only what both have is bridged.
nonisolated(unsafe) var extraGraphs: [String] = [] // safe: the generator runs on one thread
nonisolated(unsafe) var manifestPath: String? // safe: the generator runs on one thread
nonisolated(unsafe) var otherPlatformPaths: [String] = [] // safe: the generator runs on one thread
do {
    let rest = Array(arguments.dropFirst(3))
    var i = 0
    while i < rest.count {
        switch rest[i] {
        case "--manifest" where i + 1 < rest.count: manifestPath = rest[i + 1]; i += 2
        case "--also" where i + 1 < rest.count: otherPlatformPaths.append(rest[i + 1]); i += 2
        default: extraGraphs.append(rest[i]); i += 1
        }
    }
}
/// What the other platforms declare, by module: a member is bridged only if
/// every one of them has it.
let otherPlatforms: [Set<String>] = try otherPlatformPaths.map { Set(try Manifest(contentsOf: $0).members) }
/// What this platform declares, whatever the others have and whatever the
/// generator can make of it.
nonisolated(unsafe) var thisPlatform: Set<String> = [] // safe: the generator runs on one thread
func readGraph(_ path: String) throws -> Graph {
    try JSONDecoder().decode(Graph.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
}
/// The module's graph, with what other modules add to its types and
/// protocols (`_StringProcessing`'s `contains(_:)` on Collection).
nonisolated(unsafe) var addedByOthers: Set<String> = [] // safe: the generator runs on one thread
nonisolated(unsafe) var extraModules: [String] = [] // safe: the generator runs on one thread
let graph: Graph = try {
    var graph = try readGraph(arguments[1])
    for path in extraGraphs {
        let extra = try readGraph(path)
        if !extraModules.contains(extra.module.name) { extraModules.append(extra.module.name) }
        addedByOthers.formUnion(extra.symbols.map(\.identifier.precise))
        graph = Graph(module: graph.module, symbols: graph.symbols + extra.symbols, relationships: graph.relationships + extra.relationships)
    }
    return graph
}()

/// What's bridged from each module: its types, with their generic
/// parameters, and the name of the list the output declares.
struct BridgedModule {
    /// The name of the list the output declares.
    let list: String
    /// The types, with their generic parameters.
    let types: [(String, [String])]
    /// The name of the list of free functions the output declares, if it bridges them.
    let functions: String?
    /// Types of other modules that its signatures use, held as they are.
    let external: [String]

    init(_ list: String, _ types: [(String, [String])], _ functions: String?, _ external: [String]) {
        self.list = list
        self.types = types
        self.functions = functions
        self.external = external
    }
}

let modules: [String: BridgedModule] = [
    "Swift": BridgedModule("standardLibrary", [
        ("String", []), ("Substring", []), ("Character", []), ("Unicode.Scalar", []), ("Int", []), ("Double", []), ("Bool", []),
        ("Array", ["Element"]), ("ArraySlice", ["Element"]), ("Set", ["Element"]), ("Dictionary", ["Key", "Value"]),
        ("Optional", ["Wrapped"]), ("Range", ["Bound"]), ("ClosedRange", ["Bound"]),
    ], nil, []),
    // FilePath.Root is left out: the standard library's FilePath (SE-0529)
    // calls it Anchor.
    "SystemPackage": BridgedModule("system", [("FilePath", []), ("FilePath.Component", []), ("FilePath.ComponentView", [])], nil, []),
    // Foundation's types Swiit holds as Swift's: a date.
    "Foundation": BridgedModule("foundation", [("Date", []), ("AttributedString", [])], nil, []),
]
guard let module = modules[graph.module.name] else {
    FileHandle.standardError.write(Data("swiit-bridge: nothing to bridge from \(graph.module.name)\n".utf8))
    exit(2)
}
let bridgedTypeNames = module.types
let access = "internal"
for symbol in graph.symbols where symbol.kind.identifier == "swift.typealias" && symbol.pathComponents.count == 1 {
    let text = (symbol.declarationFragments ?? []).map(\.spelling).joined()
    guard let equals = text.range(of: "=") else { continue }
    var reader = Reader(String(text[equals.upperBound...]))
    if let target = try? reader.type() { topLevelAliases[symbol.pathComponents[0]] = target }
}
externalTypes = Set(module.external + module.types.map(\.0))
for name in module.external where leaves[name] == nil {
    leaves[name] = Leaf(".named(\(quoted(name)))", { "try SwiftValue.unbox(\(name).self, \($0))" }, { "SwiftValue.make(\($0), as: \(quoted(name)))" })
}

/// A public enum or struct of the module is declared in Swiit from its
/// cases or fields (`standardTypes`, Swiit source read with the prelude).
/// Results only: a struct is made a record by encoding it, an enum a case
/// by name. Enums come first, for the structs that have them.
nonisolated(unsafe) var resultOnly: Set<String> = [] // safe: the generator runs on one thread
nonisolated(unsafe) var enumNames: Set<String> = [] // safe: the generator runs on one thread
var typeSources: [String] = []
// A type the module holds as Swift's (`FileSize`) is known before its structs' fields are read, which may be of it.
for (name, parameters) in bridgedTypeNames where parameters.isEmpty && leaves[name] == nil {
    leaves[name] = Leaf(".named(\(quoted(name)))", { "try SwiftValue.unbox(\(name).self, \($0))" }, { "SwiftValue.make(\($0), as: \(quoted(name)))" })
}
do {
    // The module's own types, and when it's read as another module's
    // addition, the same: what it adds is known as it is declared.
    let candidates = module.functions != nil ? graph.symbols : graph.symbols.filter { addedByOthers.contains($0.identifier.precise) }
    let publicTypes = candidates.filter { $0.pathComponents.count == 1 && $0.accessLevel == "public" }
    for symbol in publicTypes where symbol.kind.identifier == "swift.enum" {
        let name = symbol.pathComponents[0]
        // The styles text is shown in belong to the printers, not to a script.
        if name == "DisplayStyle" { continue }
        let cases = publicMembers(of: name, "swift.enum.case")
        // Cases with associated values would need their payloads bridged.
        guard !cases.isEmpty, !cases.contains(where: { ($0.declarationFragments ?? []).contains { $0.spelling.contains("(") } }) else { continue }
        let protocols = conformances(of: symbol, among: ["Equatable", "Hashable", "Comparable"])
        typeSources.append("\(declaredType(symbol))enum \(name)\(protocols.isEmpty ? "" : ": " + protocols.joined(separator: ", ")) {\n    case \(cases.map { $0.pathComponents[1] }.joined(separator: ", "))\n}")
        enumNames.insert(name)
        // A case is found by name among all of them, so it can be an
        // argument if the enum lists them; if not, it's a result only.
        let iterable = !conformances(of: symbol, among: ["CaseIterable"]).isEmpty
        if !iterable { resultOnly.insert(name) }
        leaves[name] = Leaf(".named(\(quoted(name)))", { iterable ? "try bridgeCase(\(name).self, \($0))" : "fatalError()" },
                        { "interpreter.declaredCase(\(quoted(name)), String(describing: \($0)))" })
    }
    for symbol in publicTypes where symbol.kind.identifier == "swift.struct" {
        let name = symbol.pathComponents[0]
        // A type the module holds as Swift's and bridges the members of is no record.
        if module.types.contains(where: { $0.0 == name }) { continue }
        let protocols = conformances(of: symbol, among: ["Equatable", "Hashable", "Encodable"])
        guard protocols.contains("Encodable") else { continue }
        let fields = publicMembers(of: name, "swift.property")
        var declared: [String] = []
        var patches: [String] = []
        for field in fields {
            let text = (field.declarationFragments ?? []).map(\.spelling).joined()
            guard let declaration = try? parseDeclaration(text), let type = declaration.returns, let found = fieldType(type) else { break }
            declared.append("    let \(field.pathComponents[1]): \(found.source)")
            if let patch = found.patch { patches.append("\(quoted(field.pathComponents[1])): \(patch)") }
        }
        guard declared.count == fields.count else {
            FileHandle.standardError.write(Data("\(name): a field Swiit can't hold; left out\n".utf8))
            continue
        }
        typeSources.append("\(declaredType(symbol))struct \(name): \(protocols.joined(separator: ", ")) {\n\(declared.joined(separator: "\n"))\n}")
        resultOnly.insert(name)
        let patchesCode = patches.isEmpty ? "" : ", patches: [\(patches.joined(separator: ", "))]"
        leaves[name] = Leaf(".named(\(quoted(name)))", { _ in fatalError("a record is a result, not an argument") },
                        { "bridgeRecord(interpreter, \($0)\(patchesCode))" })
    }
}
// Other types that aren't generic, Swiit having no value of its own for
// them (Character, FilePath), are held as they are, boxed.
for (name, parameters) in bridgedTypeNames where parameters.isEmpty && leaves[name] == nil {
    leaves[name] = Leaf(".named(\(quoted(name)))", { "try SwiftValue.unbox(\(name).self, \($0))" }, { "SwiftValue.make(\($0), as: \(quoted(name)))" })
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
for symbol in graph.symbols where symbol.kind.identifier == "swift.struct" || symbol.kind.identifier == "swift.enum" {
    typeIDs[symbol.pathComponents] = symbol.identifier.precise
}
let symbolsByID = Dictionary(graph.symbols.map { ($0.identifier.precise, $0) }, uniquingKeysWith: { first, _ in first })


/// The protocols the module declares: where their members are listed.
let protocolNames = Set(graph.symbols.filter { $0.kind.identifier == "swift.protocol" }.map(\.pathComponents[0]))

nonisolated(unsafe) var types: [String: BridgedType] = [:] // safe: the generator runs on one thread
for (name, parameters) in bridgedTypeNames {
    var type = BridgedType(name: name, parameters: parameters)
    let path = name.split(separator: ".").map(String.init)
    for symbol in graph.symbols where symbol.pathComponents.dropLast() == path[...]
        && symbol.kind.identifier == "swift.typealias" {
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
    for relationship in graph.relationships where relationship.kind == "conformsTo" && relationship.source == id {
        var proto = relationship.targetFallback.map { String($0.split(separator: ".").last!) }
            ?? symbolsByID[relationship.target]?.pathComponents.last ?? ""
        type.allConformances.insert(proto)
        if proto == "Collection" || proto == "BidirectionalCollection" { proto = "Sequence" }
        guard knownProtocols.contains(proto) else { continue }
        // What the generic parameters must be for it, if Swiit can say.
        var needs: [String: [String]] = [:]
        var sayable = true
        for constraint in relationship.swiftConstraints ?? [] where !alwaysMet.contains(constraint.rhs) {
            if strideFix(constraint) { needs["Bound"] = ["=Int"]; continue }
            if constraint.lhs.contains(".") { continue } // Bound.Stride, with Bound an Int
            if valueProtocols.contains(constraint.rhs) || constraint.rhs == "Encodable" {
                if needs[constraint.lhs] != ["=Int"] { needs[constraint.lhs, default: []].append(constraint.rhs) }
            } else {
                sayable = false
            }
        }
        guard sayable else { continue }
        // Of a conformance declared more than once, the least demanding.
        if let existing = type.conformances[proto], existing.values.map(\.count).reduce(0, +) <= needs.values.map(\.count).reduce(0, +) { continue }
        type.conformances[proto] = needs.mapValues { Array(Set($0)).sorted() }
    }
    types[name] = type
}








var output = """
// Generated by swiit-bridge from the \(graph.module.name) module's symbol graph.
// Don't edit: the bridge generator (swiit-bridge) remakes it.
import Foundation
\(graph.module.name == "Swift" ? "" : "import \(graph.module.name)\n")\(module.external.isEmpty ? "" : "import SystemPackage\n")\(extraModules.map { "import \($0)\n" }.joined())
extension Bridge {
\(module.types.isEmpty ? "" : "    \(access) nonisolated(unsafe) static let \(module.list): [BridgedType] = [\n")

"""
var skipped: [String: Int] = [:]
var counts: [String: Int] = [:]
/// Each member is a declaration of its own, not an element of one big
/// array: Swift checks an expression at a time, and 80 closures in a literal
/// take gigabytes to check together.
nonisolated(unsafe) var declarations: [String] = [] // safe: the generator runs on one thread
func declare(_ expression: String) -> String {
    let name = "member\(declarations.count)"
    declarations.append("    nonisolated(unsafe) private static let \(name): BridgedMember = \(expression)\n")
    return name
}

for (name, _) in bridgedTypeNames {
    // A type of another module is known to the generator as it is: what is made is only what this module adds to it.
    let owner = types[name] ?? BridgedType(name: name, parameters: [])
    var seen: Set<String> = []
    var members: [String] = []
    let kinds = ["swift.method", "swift.property", "swift.init", "swift.type.method", "swift.type.property", "swift.func.op"]
    // Its own members, then those of the protocols it conforms to, whether
    // required or added by an extension (`Collection.contains`,
    // `Sequence.max`), which the graph lists under the protocol, not the
    // type. The type's own member of the same name and labels hides the
    // protocol's, as in Swift (`Set.union(_: Sequence)` over
    // `SetAlgebra.union(_: Self)`); if it can't be bridged, the protocol's is
    // what there is (String's `reversed` gives a ReversedCollection, which
    // Swiit has no value for, but Sequence's gives an array).
    let path = name.split(separator: ".").map(String.init)
    let ownSymbols = graph.symbols.filter { $0.pathComponents.dropLast() == path[...] }
    var candidates = ownSymbols.map { ($0, [Constraint]()) }
    // A range is a sequence only when `Bound: Strideable` with a
    // SignedInteger stride: for Swiit, when Bound is Int.
    let conditions = name == "Range" || name == "ClosedRange"
        ? [Constraint(kind: "conformance", lhs: "Bound", rhs: "Strideable"),
           Constraint(kind: "conformance", lhs: "Bound.Stride", rhs: "SignedInteger")]
        : []
    candidates += graph.symbols.filter {
        // Not initializers: a protocol's is a requirement the type meets
        // with its own, which isn't the same call.
        $0.pathComponents.count == 2 && protocolNames.contains($0.pathComponents[0]) && $0.kind.identifier != "swift.init"
            && owner.allConformances.contains($0.pathComponents[0])
    }.map { ($0, conditions) }
    var bridgedShapes: Set<String> = []
    let ownCount = ownSymbols.count
    for (index, (symbol, conditions)) in candidates.enumerated() {
        guard kinds.contains(symbol.kind.identifier), symbol.accessLevel == "public", available(symbol) else { continue }
        let title = symbol.pathComponents.last!
        // Operators of a type from another module: the standard library's
        // (Int, String…) are the host's own, which doesn't ask Swift.
        let isOperator = symbol.kind.identifier == "swift.func.op"
        guard !title.hasPrefix("_"), title.first?.isLetter ?? false || isOperator && graph.module.name != "Swift" else { continue }
        // The interpreter's own hooks a type adopts (`swiitDescription`), not for Swiit code.
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
            let (key, shape, codes) = (bridged.key, bridged.shape, bridged.codes)
            // What another module adds is an overload, not a default.
            if index >= ownCount, bridgedShapes.contains(shape), !addedByOthers.contains(symbol.identifier.precise) { continue }
            guard seen.insert(key).inserted else { continue }
            if index < ownCount { bridgedShapes.insert(shape) }
            members.append(contentsOf: codes.map(declare))
            counts[name, default: 0] += 1
        } catch let unsupported as Unsupported {
            // SWIIT_BRIDGE_DEBUG=Set: why each of a type's members is left out.
            if ProcessInfo.processInfo.environment["SWIIT_BRIDGE_DEBUG"] == name {
                FileHandle.standardError.write(Data("\(title): \(unsupported.reason)\n".utf8))
            }
            skipped[unsupported.reason.split(separator: " ").first.map(String.init) ?? "?", default: 0] += 1
        }
    }
    let context = Context(owner: owner, generics: Set(owner.genericParameters))
    let associated = owner.associated.compactMap { key, value -> String? in
        guard let resolved = resolve(value, context), supported(resolved, generics: context.generics, asParameter: false) else { return nil }
        return "\(quoted(key)): \(annotation(resolved))"
    }.sorted()
    let conformances = owner.conformances.sorted { $0.key < $1.key }.map { proto, needs in
        let needsCode = needs.isEmpty ? "[:]" : "[" + needs.sorted { $0.key < $1.key }.map { "\(quoted($0.key)): [\($0.value.map(quoted).joined(separator: ", "))]" }.joined(separator: ", ") + "]"
        return "\(quoted(proto)): \(needsCode)"
    }
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
       graph.symbols.contains(where: { $0.pathComponents == [name, $0.pathComponents.last!]
           && $0.kind.identifier == "swift.init" && available($0) && isSequenceInitializer($0) }) {
        let collection = selfType(owner)
        arrayLiteral = "{ \(toValue("\(spelling(collection))($0)", collection)) }"
    }
    if owner.parameters.isEmpty {
        let selfType = SType.named(name, [])
        if graph.symbols.contains(where: { $0.pathComponents == name.split(separator: ".").map(String.init) + [$0.pathComponents.last!]
            && $0.kind.identifier == "swift.init" && available($0) && isTextInitializer($0) }) {
            parse = "{ \(name)($0).map { \(toValue("$0", selfType)) } }"
        }
        if owner.allConformances.contains("ExpressibleByUnicodeScalarLiteral") {
            literal = "{ textLiteral(\(name).self, $0).map { \(toValue("$0", selfType)) } }"
        }
    }
    output += """
        BridgedType(
            name: \(quoted(name)), genericParameters: [\(owner.parameters.map(quoted).joined(separator: ", "))],
            conformances: [\(conformances.isEmpty ? ":" : conformances.joined(separator: ", "))],
            associatedTypes: [\(associated.isEmpty ? ":" : associated.joined(separator: ", "))],
            parse: \(parse), literal: \(literal), arrayLiteral: \(arrayLiteral),
            members: [
                \(members.joined(separator: ", "))
            ]
        ),

"""
}
if !module.types.isEmpty { output += "    ]\n" }
if let list = module.functions {
    output += "    /// The module's structs, as Swiit source: declared with the prelude.\n"
    // What the module is called in the names of its tables: `standard` for
    // `standardFunctions`.
    let prefix = String(list.dropLast("Functions".count))
    output += "    \(access) static let \(prefix)Types = #\"\"\"\n" + typeSources.joined(separator: "\n\n") + "\n\"\"\"#\n\n"
    var functions: [String] = []
    for symbol in graph.symbols where symbol.kind.identifier == "swift.func" && symbol.pathComponents.count == 1
        && symbol.accessLevel == "public" && available(symbol) {
        do {
            let bridged = try bridge(symbol, of: BridgedType(name: "", parameters: []), free: true)
            functions += bridged.codes.map(declare)
        } catch let unsupported as Unsupported {
            FileHandle.standardError.write(Data("\(symbol.pathComponents[0]): \(unsupported.reason)\n".utf8))
        }
    }
    output += "    \(access) nonisolated(unsafe) static let \(list): [BridgedMember] = [\(functions.joined(separator: ", "))]\n"
}
output += declarations.joined(separator: "\n") + "}\n"
try output.write(to: URL(fileURLWithPath: arguments[2]), atomically: true, encoding: .utf8)
if let manifestPath {
    try Manifest(platform: Manifest.current, module: graph.module.name, members: thisPlatform.sorted()).write(to: manifestPath)
}
let total = counts.values.reduce(0, +)
FileHandle.standardError.write(Data("bridged \(total) members (\(bridgedTypeNames.map { "\($0.0) \(counts[$0.0] ?? 0)" }.joined(separator: ", "))); left out: \(skipped.sorted { $0.value > $1.value }.prefix(12).map { "\($0.key) \($0.value)" }.joined(separator: ", "))\n".utf8))
