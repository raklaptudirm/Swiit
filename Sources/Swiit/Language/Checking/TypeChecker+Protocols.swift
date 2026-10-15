import Foundation
import SwiitKit

extension TypeChecker {
    // MARK: Protocols

    func protocolInfo(_ decl: ProtocolDecl) -> ProtocolInfo {
        func signatures(_ declared: [FunctionDecl]) -> [String: [Signature]] {
            var result: [String: [Signature]] = [:]
            for method in declared {
                var signature = Signature(name: method.name, parameters: method.parameters, returns: method.returnType ?? .void,
                                          isMutating: method.isMutating, isThrowing: method.isThrowing, effect: method.effect,
                                          generics: method.generics)
                signature.index = result[method.name]?.count ?? 0
                result[method.name, default: []].append(signature)
            }
            return result
        }
        var info = ProtocolInfo(name: decl.name, inherited: decl.inherited)
        info.methods = signatures(decl.methods)
        info.staticMethods = signatures(decl.staticMethods)
        for property in decl.properties { info.properties[property.name] = (property.type, property.settable) }
        for property in decl.staticProperties { info.staticProperties[property.name] = property.type }
        info.initializers = decl.initializers.enumerated().map { index, initializer in
            Signature(name: "init", parameters: initializer.parameters, returns: .named(decl.name), isMutating: true,
                      isThrowing: initializer.isThrowing, index: index)
        }
        return info
    }

    func protocolInfo(named name: String) -> ProtocolInfo? {
        if case .protocolType(let info)? = lookup(name) { return info }
        // `A & B`: what both ask.
        if name.contains(" & ") { return ProtocolInfo(name: name, inherited: name.components(separatedBy: " & ")) }
        return nil
    }

    /// The protocol and every one it takes in, directly or not.
    func protocolClosure(_ name: String) -> [String] {
        var result: [String] = []
        var queue = [name]
        while !queue.isEmpty {
            let next = queue.removeFirst()
            guard !result.contains(next) else { continue }
            result.append(next)
            queue += protocolInfo(named: next)?.inherited ?? []
        }
        return result
    }

    /// What every protocol in the closure asks.
    private func requirements(_ name: String) -> [ProtocolInfo] {
        protocolClosure(name).compactMap(protocolInfo(named:))
    }

    /// Whether a value of `type` may be used as the protocol: it conforms.
    func conformsToProtocol(_ type: TypeAnnotation, _ name: String) -> Bool {
        guard protocolInfo(named: name) != nil else { return false }
        return conforms(type, to: name)
    }

    /// A type that says it conforms to a protocol of the program's has what the protocol asks, or a default for it.
    func checkConformance(of typeName: String, to protocolName: String) throws {
        guard protocolInfo(named: protocolName) != nil else { return }
        let ext = extensionInfo(forKey: typeName)
        let info = structInfo(named: typeName)
        let enumeration = enumInfo(named: typeName)
        func has(method name: String, labels: [String?]) -> Bool {
            let own = info?.methods[name] ?? enumeration?.methods[name] ?? []
            return (own + (ext?.methods[name] ?? [])).contains { $0.parameters.map(\.label) == labels }
        }
        func has(staticMethod name: String, labels: [String?]) -> Bool {
            let own = info?.staticMethods[name] ?? enumeration?.staticMethods[name] ?? []
            return (own + (ext?.staticMethods[name] ?? [])).contains { $0.parameters.map(\.label) == labels }
        }
        func has(property name: String, settable: Bool) -> Bool {
            if let stored = info?.property(name) { return stored.mutable || !settable }
            if info?.computed[name] != nil || enumeration?.computed[name] != nil || ext?.computed[name] != nil {
                return !settable || info?.settable.contains(name) == true || ext?.settable.contains(name) == true
            }
            return false
        }
        for required in requirements(protocolName) {
            for (name, signatures) in required.methods.sorted(by: { $0.key < $1.key }) {
                for signature in signatures where !has(method: name, labels: signature.parameters.map(\.label)) {
                    throw TypeError("\(typeName) doesn't conform to \(protocolName): it needs \(name)(\(signature.parameters.map { ($0.label ?? "_") + ":" }.joined()))")
                }
            }
            for (name, property) in required.properties.sorted(by: { $0.key < $1.key }) where !has(property: name, settable: property.settable) {
                throw TypeError("\(typeName) doesn't conform to \(protocolName): it needs the \(property.settable ? "settable " : "")property '\(name)'")
            }
            for (name, signatures) in required.staticMethods.sorted(by: { $0.key < $1.key }) {
                for signature in signatures where !has(staticMethod: name, labels: signature.parameters.map(\.label)) {
                    throw TypeError("\(typeName) doesn't conform to \(protocolName): it needs static \(name)(\(signature.parameters.map { ($0.label ?? "_") + ":" }.joined()))")
                }
            }
            for initializer in required.initializers {
                let labels = initializer.parameters.map(\.label)
                let provided = (info?.initializers ?? []) + (info.map { $0.initializers.isEmpty ? [$0.memberwise] : [] } ?? []) + (ext?.initializers ?? [])
                guard provided.contains(where: { $0.parameters.map(\.label) == labels }) else {
                    throw TypeError("\(typeName) doesn't conform to \(protocolName): it needs init(\(labels.map { ($0 ?? "_") + ":" }.joined()))")
                }
            }
        }
    }

    /// What a value of a protocol's type has: its requirements, and what extensions of it add.
    func protocolMemberType(_ protocolName: String, _ name: String) -> TypeAnnotation? {
        for required in requirements(protocolName) {
            if let property = required.properties[name] { return property.type }
            if let methods = required.methods[name] { return methods.count == 1 ? functionType(methods[0]) : .function }
        }
        if let ext = extensionInfo(forKey: protocolName) {
            if let computed = ext.computed[name] { return computed }
            if let methods = ext.methods[name] { return methods.count == 1 ? functionType(methods[0]) : .function }
        }
        return nil
    }

    /// The overloads of a protocol's method, the requirements and the defaults an extension gives.
    func protocolMethods(_ protocolName: String, _ name: String) -> [Signature] {
        var found: [Signature] = []
        for required in requirements(protocolName) { found += required.methods[name] ?? [] }
        if found.isEmpty { found = extensionInfo(forKey: protocolName)?.methods[name] ?? [] }
        return found.enumerated().map { index, signature in var copy = signature; copy.index = index; return copy }
    }
}
