import Foundation

// MARK: Bridging

/// Swish's own values, and how Swift's are held in them.
nonisolated(unsafe) var leaves: [String: (annotation: String, from: (String) -> String, to: (String) -> String)] = [
    "Int": (".int", { "try Int(swishValue: \($0))" }, { "\($0).swishValue" }),
    "Double": (".double", { "try Double(swishValue: \($0))" }, { "\($0).swishValue" }),
    "Bool": (".bool", { "try Bool(swishValue: \($0))" }, { "\($0).swishValue" }),
    "String": (".string", { "try String(swishValue: \($0))" }, { "\($0).swishValue" }),
    // Swish's own value, passed as it is: what a function that lays values
    // out takes. Spelled `SwishValue`, which a generic parameter called
    // `Value` (Dictionary's) can't be mistaken for.
    "SwishValue": (".any", { $0 }, { $0 }),
]

/// A module's own top-level typealiases (`TimeInterval` is `Double`), which
/// a signature may use.
nonisolated(unsafe) var topLevelAliases: [String: SType] = [:]

/// Generic types Swish holds as they are, boxed (`SwiftValue`), with Swish's
/// values for their generic parameters: a `Set<Int>` is a `Set<Value>`.
let boxes: Set = ["Set", "ArraySlice", "Range", "ClosedRange", "Flow"]

/// The protocols a type conforms to, as far as the checker needs to know.
let knownProtocols: Set = ["Equatable", "Hashable", "Comparable", "CustomStringConvertible", "Encodable", "Sequence", "StandsForText",
                           "ExpressibleByStringLiteral"]
/// What Swish's values (the stand-in for every generic parameter) can be.
let valueProtocols: Set = ["Equatable", "Hashable", "Comparable"]
/// Constraints every Swish value meets, so they say nothing.
let alwaysMet: Set = ["Copyable", "Escapable", "Sendable", "SendableMetatype"]

struct BridgedType {
    /// `String`, `Set`.
    let name: String
    /// Its generic parameters, all of them.
    let parameters: [String]
    /// Those not fixed to a type (by `where Element == String`).
    var genericParameters: [String]
    var fixed: [String: SType] = [:]
    var associated: [String: SType] = [:]
    /// The protocols it conforms to that the checker knows, each with what
    /// its generic parameters must be for it.
    var conformances: [String: [String: [String]]] = [:]
    /// Every protocol it conforms to, for constraints like `Self: FixedWidthInteger`.
    var allConformances: Set<String> = []

    init(name: String, parameters: [String]) {
        self.name = name
        self.parameters = parameters
        self.genericParameters = parameters
    }
}

/// What a member's types are resolved against.
struct Context {
    var owner: BridgedType
    /// The member's own generic parameters, and the owner's.
    var generics: Set<String>
    /// Its parameters that are sequences, with their elements.
    var sequences: [String: SType] = [:]
}

/// The type a member's `Self` is.
func selfType(_ owner: BridgedType) -> SType {
    let arguments = owner.parameters.map { owner.fixed[$0] ?? .named($0, []) }
    switch owner.name {
    case "Array": return .array(arguments[0])
    case "Optional": return .optional(arguments[0])
    case "Dictionary": return .dictionary(arguments[0], arguments[1])
    default: return .named(owner.name, arguments)
    }
}

/// A type as a member of the context's owner sees it: `Self`, associated
/// types and sequence parameters replaced. Nil when it can't be bridged.
func resolve(_ type: SType, _ context: Context) -> SType? {
    let owner = context.owner
    switch type {
    case .named("Self", []):
        return selfType(owner)
    case .named(let name, let arguments):
        if arguments.isEmpty, let element = context.sequences[name] { return resolve(element, context).map(SType.someSequence) }
        if arguments.isEmpty, let target = topLevelAliases[name] { return resolve(target, context) }
        if context.generics.contains(name) || owner.genericParameters.contains(name) { return arguments.isEmpty ? type : nil }
        if arguments.isEmpty, let target = owner.associated[name] { return resolve(target, context) }
        if name == "Void" { return .tuple([]) }
        let resolved = arguments.compactMap { resolve($0, context) }
        guard resolved.count == arguments.count else { return nil }
        if name == "Array", resolved.count == 1 { return .array(resolved[0]) }
        if name == "Optional", resolved.count == 1 { return .optional(resolved[0]) }
        if name == "Dictionary", resolved.count == 2 { return .dictionary(resolved[0], resolved[1]) }
        return .named(name, resolved)
    case .member(let base, let name):
        // `S.Element`, for a sequence parameter S.
        if case .named(let parameter, []) = base, let element = context.sequences[parameter] {
            return name == "Element" ? resolve(element, context) : nil
        }
        // `FilePath.Component`: a nested type that's bridged too.
        if case .named(let outer, []) = base, types["\(outer).\(name)"] != nil { return .named("\(outer).\(name)", []) }
        guard let resolvedBase = resolve(base, context) else { return nil }
        // `Self.Element`: a generic parameter (on Array) or an associated type.
        if resolvedBase == selfType(owner) {
            if owner.genericParameters.contains(name) { return .named(name, []) }
            if let target = owner.associated[name] { return resolve(target, context) }
        }
        // `Bound.Stride`, with Bound fixed to Int: Int's own.
        if case .named(let leaf, []) = resolvedBase, let other = types[leaf], let target = other.associated[name] {
            return resolve(target, Context(owner: other, generics: []))
        }
        return nil
    case .array(let element): return resolve(element, context).map(SType.array)
    case .optional(let wrapped): return resolve(wrapped, context).map(SType.optional)
    case .dictionary(let key, let value):
        guard let key = resolve(key, context), let value = resolve(value, context) else { return nil }
        return .dictionary(key, value)
    case .tuple(let elements):
        let resolved = elements.compactMap { element in resolve(element.type, context).map { SType.Element(label: element.label, type: $0) } }
        return resolved.count == elements.count ? .tuple(resolved) : nil
    case .function(let parameters, let result, let throwing):
        let resolved = parameters.compactMap { resolve($0, context) }
        guard resolved.count == parameters.count, let result = resolve(result, context) else { return nil }
        return .function(resolved, result, throwing: throwing)
    case .someSequence:
        return type
    }
}

/// A leaf type or a generic parameter: what can be in a box or a dictionary.
func isSimple(_ type: SType, generics: Set<String>) -> Bool {
    guard case .named(let name, []) = type else { return false }
    return leaves[name] != nil || generics.contains(name)
}

/// Whether Swish can hold or pass `type`: its values, the leaf types above,
/// generic parameters (as Swish values), boxes, and arrays, dictionaries,
/// optionals, tuples and closures of those. Closures only as parameters.
func supported(_ type: SType, generics: Set<String>, asParameter: Bool) -> Bool {
    switch type {
    case .named(let name, let arguments):
        if arguments.isEmpty { return isSimple(type, generics: generics) }
        // A key path, which Swish reads by field name: `KeyPath<Element, V>`.
        // Only over generic parameters, which are Swish's values: the path
        // reads fields of them, as it can't of a Character.
        if name == "KeyPath", arguments.count == 2 {
            return asParameter && arguments.allSatisfy { if case .named(let n, []) = $0 { generics.contains(n) } else { false } }
        }
        return boxes.contains(name) && arguments.allSatisfy { isSimple($0, generics: generics) }
    case .array(let element), .optional(let element), .someSequence(let element):
        return supported(element, generics: generics, asParameter: false)
    case .dictionary(let key, let value):
        return isSimple(key, generics: generics) && isSimple(value, generics: generics)
    case .tuple(let elements):
        return elements.allSatisfy { element in
            if case .function = element.type { return false }
            return supported(element.type, generics: generics, asParameter: false)
        }
    case .function(let parameters, let result, _):
        return asParameter && parameters.allSatisfy { supported($0, generics: generics, asParameter: false) }
            && supported(result, generics: generics, asParameter: false)
    case .member:
        return false
    }
}
