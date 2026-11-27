import Foundation

/// What a type has beyond what it was declared with: an enum's computed
/// properties and methods, or what extensions add to any type.
final class TypeMembers {
    var computed: [String: Function] = [:]
    var setters: [String: Function] = [:]
    var methods: [String: OverloadSet] = [:]
    var staticComputed: [String: Function] = [:]
    /// The setters of `static var`s that are computed.
    var staticSetters: [String: Function] = [:]
    var staticMethods: [String: OverloadSet] = [:]
    var statics: [String: StructType.StaticValue] = [:]
    var staticProperties: [PropertyDecl] = []
    var initializers: OverloadSet?
    var subscriptGetters: [Function] = []
    var subscriptSetters: [Function?] = []
    /// Protocols added by `extension T: P`.
    var conformances: [String] = []
}

extension Interpreter {
    /// Builds the functions of a type's declared members into `members`, adding to what is there.
    func fill(_ members: TypeMembers, of name: String, from source: StructDecl) throws {
        members.staticProperties += source.staticProperties
        members.computed.merge(computedProperties(of: source.properties)) { _, new in new }

        // A type that is not a class has no stored properties to observe here.
        _ = declareSettersAndObservers(source.properties, in: members)

        append(
            overloads(of: source.methods, honorsMutating: true) { .swiit($0.body) },
            to: &members.methods
        )
        members.staticComputed.merge(staticFunctions(of: source.staticProperties).getters) {
            _,
            new in new
        }
        append(overloads(of: source.staticMethods) { .swiit($0.body) }, to: &members.staticMethods)

        let made = initializerFunctions(of: source.initializers, in: name)
        if !made.isEmpty {
            members.initializers = OverloadSet(
                name: "\(name).init",
                candidates: (members.initializers?.candidates ?? []) + made
            )
        }

        declareSubscripts(source.subscripts, in: members)

        // Static values, which may be of the type itself, which is declared by now.
        try evaluateStaticValues(source.staticProperties, in: members, named: name)
    }

    /// Adds overloads to a table, after those it already has under the same name.
    private func append(_ added: [String: OverloadSet], to table: inout [String: OverloadSet]) {
        for (name, set) in added {
            table[name] = OverloadSet(
                name: name,
                candidates: (table[name]?.candidates ?? []) + set.candidates
            )
        }
    }

    /// `extension Int { … }`: members and protocols added to a type, by its name.
    func declare(_ decl: ExtensionDecl) throws {
        let members = typeExtensions[decl.typeName] ?? TypeMembers()
        typeExtensions[decl.typeName] = members
        members.conformances += decl.conformances
        try fill(members, of: decl.typeName, from: decl.members)
    }

    /// What names a value's type: `Int`, a struct's own name, `Array`.
    func typeKey(of value: Value) -> String? {
        if let name = value.representation?.name { return name }
        return switch value.storage {
        case .structure(let structure): structure.record.typeName
        case .enumValue(let enumValue): enumValue.type.name
        case .object(let box as SwiftValue): box.typeName
        default: nil
        }
    }

    /// The members extensions add to a value's type (and protocols it conforms to) with a method of
    /// that name.
    func extensionMethods(_ name: String, of value: Value) -> OverloadSet? {
        extensionChain(of: value).lazy.compactMap { $0.methods[name] }.first
    }

    /// A computed property an extension adds, or a method as a function value; nil if there isn't
    /// one.
    func extensionMember(_ name: String, of value: Value) throws -> Value? {
        for members in extensionChain(of: value) {
            if let found = try extensionMember(name, of: value, in: members) { return found }
        }
        return nil
    }

    private func extensionMember(
        _ name: String,
        of value: Value,
        in members: TypeMembers
    ) throws -> Value? {
        if let getter = members.computed[name] {
            return try invoke(getter, with: [:], receiver: Receiver(value, mutable: false))
        }
        guard let methods = members.methods[name] else { return nil }
        let bound = methods.candidates.map { method in
            Function(
                name: method.name,
                parameters: method.parameters,
                returnType: method.returnType,
                body: .native { interpreter, arguments in
                    guard !method.isMutating else {
                        throw RuntimeError(
                            "mutating method '\(name)' must be called on a variable, as in value.\(name)(…)"
                        )
                    }
                    return try interpreter.invoke(
                        method,
                        with: arguments,
                        receiver: Receiver(value, mutable: false)
                    )
                },
                documentation: method.documentation,
                attributes: method.attributes,
                isMutating: method.isMutating
            )
        }
        return .function(OverloadSet(name: name, candidates: bound))
    }

    /// The name of the type a type value stands for: a struct's, an enum's, or Swift's.
    func declaredTypeName(of typeValue: Value) -> String? {
        guard case .object(let object) = typeValue.storage else { return nil }
        return switch object {
        case let type as StructType: type.name
        case let type as Value.EnumCase.Enumeration: type.name
        case let type as NativeTypeName: type.name
        default: nil
        }
    }

    /// `P.zero`, `P.make`: what an extension adds to a type as static members.
    func extensionStaticMember(_ name: String, ofTypeNamed typeName: String) throws -> Value? {
        guard let members = typeExtensions[typeName] else { return nil }
        if let getter = members.staticComputed[name] { return try invoke(getter, with: [:]) }
        if let slot = members.statics[name] { return slot.value }
        return members.staticMethods[name].map(Value.function)
    }

    /// The protocols a type was declared with, and extensions gave it.
    func conformances(ofTypeNamed name: String, declared: [String]) -> [String] {
        declared + (typeExtensions[name]?.conformances ?? [])
    }
}
