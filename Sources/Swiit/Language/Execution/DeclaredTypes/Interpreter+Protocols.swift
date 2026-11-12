import Foundation

// safe: its state is touched only holding the interpreter lock
/// A protocol a program declares: what a value of a type conforming to it can be asked as.
final class ProtocolType: LanguageObject, DeclaredType, @unchecked Sendable {
    let name: String
    let id: Symbol.ID
    /// The protocols it takes in: `protocol A: B`.
    let inherited: [String]
    /// What it asks of a conforming type.
    let declaration: ProtocolDecl

    init(_ declaration: ProtocolDecl) {
        self.name = declaration.name
        self.id = .declare(declaration.name)
        self.inherited = declaration.inherited
        self.declaration = declaration
    }

    var typeName: String { "protocol" }
    var memberNames: [String] { [] }
    func member(_ name: String) -> Value? { nil }
    var description: String { "protocol \(name)" }
}

extension Interpreter {
    // MARK: Protocols

    /// `protocol Shape { … }`: named, so a type can say it conforms and a value can be asked.
    func declare(_ decl: ProtocolDecl) throws {
        let type = ProtocolType(decl)
        declaredTypes[type.id] = type
        scopes[scopes.count - 1].bindings[decl.name] = Binding(
            value: .object(type),
            mutable: false
        )
    }

    func protocolType(named name: String) -> ProtocolType? {
        guard case .object(let type as ProtocolType)? = lookup(name)?.value.storage else {
            return nil
        }
        return type
    }

    /// The protocols a value's type conforms to by saying so, and those those take in.
    func conformanceList(of value: Value) -> [String] {
        var declared: [String] = []
        switch value.storage {
        case .structure(let structure):
            if let type = structType(of: structure.record) { declared = type.conformances }
        case .enumValue(let enumValue):
            declared = enumConformances[ObjectIdentifier(enumValue.type)] ?? []
        case .object(let instance as ClassInstance):
            declared = instance.type.allConformances
        default:
            break
        }
        // A host's value conforms to the protocol the program declares under its type's name: that
        // is how the host describes it (`protocol Node { var label: String { get } }`).
        if case .object(let object as SwiftValue) = value.storage,
            protocolType(named: object.typeName) != nil
        {
            declared.append(object.typeName)
        }
        if case .object(let instance as ClassInstance) = value.storage {
            for type in instance.type.chain {
                declared += typeExtensions[type.name]?.conformances ?? []
            }
        } else if let key = typeKey(of: value) {
            declared += typeExtensions[key]?.conformances ?? []
        }
        declared += bridgedConformances(of: value)
        return conformances(taking: declared)
    }

    /// The protocols of Swift's that the value's type conforms to, as the bridge records them. A
    /// conformance that holds for some generic arguments only (`ClosedRange` is a sequence when
    /// its bounds are integers) is decided for the sequence protocols by whether the value can
    /// be read as one, and is left out otherwise.
    private func bridgedConformances(of value: Value) -> [String] {
        switch value.storage {
        case .int, .double, .string, .bool, .list, .dictionary: break
        case .object(let box) where box is SwiftValue: break
        default: return []
        }
        guard let key = typeKey(of: value), let type = Bridge.types[key] else { return [] }
        return type.conformances.compactMap { name, needs in
            let met = needs.allSatisfy { parameter in
                parameter.constraints.allSatisfy {
                    Bridge.valueProtocols.contains($0.refinementKey)
                }
            }
            return met
                || Bridge.sequenceProtocols.contains(name) && Interpreter.items(of: value) != nil
                ? name : nil
        }
    }

    /// What each of `declared` takes in, with them.
    private func conformances(taking declared: [String]) -> [String] {
        var result: [String] = []
        var queue = declared
        while !queue.isEmpty {
            let name = queue.removeFirst()
            guard !result.contains(name) else { continue }
            result.append(name)
            if let proto = protocolType(named: name) { queue += proto.inherited }
        }
        return result
    }

    /// Whether the type a type value stands for conforms to the protocol named.
    func typeValue(_ type: Value, conformsTo name: String) -> Bool {
        guard case .object(let object) = type.storage else { return false }
        var declared: [String] = []
        switch object {
        case let structType as StructType:
            declared =
                structType.conformances + (typeExtensions[structType.name]?.conformances ?? [])
        case let enumType as Value.EnumCase.Enumeration:
            declared =
                (enumConformances[ObjectIdentifier(enumType)] ?? [])
                + (typeExtensions[enumType.name]?.conformances ?? [])
        case let classType as ClassType:
            declared = classType.allConformances
            for above in classType.chain {
                declared += typeExtensions[above.name]?.conformances ?? []
            }
        case let named as BridgedTypeName:
            declared = typeExtensions[named.name]?.conformances ?? []
        default:
            return false
        }
        return conformances(taking: declared).contains(name)
    }

    /// Whether a value's type conforms to the protocol named.
    func value(_ value: Value, conformsTo name: String) -> Bool {
        conformanceList(of: value).contains(name)
    }

    /// What types and protocols add to a value's type, most specific first: what extensions of its
    /// type add, then the default members of each protocol it conforms to.
    func extensionChain(of value: Value) -> [TypeMembers] {
        guard !typeExtensions.isEmpty else { return [] }
        var chain: [TypeMembers] = []
        if case .object(let instance as ClassInstance) = value.storage {
            for type in instance.type.chain {
                if let own = typeExtensions[type.name] { chain.append(own) }
            }
        } else if let key = typeKey(of: value), let own = typeExtensions[key] {
            chain.append(own)
        }
        for name in conformanceList(of: value) {
            if let members = typeExtensions[name] { chain.append(members) }
        }
        return chain
    }
}
