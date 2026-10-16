import Foundation
import SwiitKit

extension TypeChecker {
    // MARK: Protocols

    func protocolInfo(_ decl: ProtocolDecl) -> TypeProfile {
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
        var info = TypeProfile(name: decl.name, kind: .protocolType)
        info.inherited = decl.inherited
        info.declared.methods = signatures(decl.methods)
        info.declared.staticMethods = signatures(decl.staticMethods)
        for property in decl.properties { info.declared.properties[property.name] = MemberProperty(type: property.type, isSettable: property.settable, stored: nil) }
        for property in decl.staticProperties { info.declared.staticProperties[property.name] = MemberProperty(type: property.type, isSettable: false, stored: nil) }
        info.declared.initializers = decl.initializers.enumerated().map { index, initializer in
            Signature(name: "init", parameters: initializer.parameters, returns: .named(decl.name), isMutating: true,
                      isThrowing: initializer.isThrowing, index: index)
        }
        return info
    }

    func protocolInfo(named name: String) -> TypeProfile? {
        if case .protocolType(let info)? = lookup(name) { return info }
        // `A & B`: what both ask.
        if name.contains(" & ") {
            var composition = TypeProfile(name: name, kind: .protocolType)
            composition.inherited = name.components(separatedBy: " & ")
            return composition
        }
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
    private func requirements(_ name: String) -> [TypeProfile] {
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
        let description = describe(named: typeName) ?? TypeProfile(name: typeName, kind: .other)
        func has(method name: String, labels: [String?]) -> Bool {
            ((description.declared.methods[name] ?? []) + (description.extended.methods[name] ?? [])).contains { $0.parameters.map(\.label) == labels }
        }
        func has(staticMethod name: String, labels: [String?]) -> Bool {
            description.staticMethods(named: name).contains { $0.parameters.map(\.label) == labels }
        }
        func has(property name: String, settable: Bool) -> Bool {
            guard case .property(let property)? = description.instanceMember(name) else { return false }
            return settable ? property.isSettable : true
        }
        for required in requirements(protocolName) {
            for (name, signatures) in required.declared.methods.sorted(by: { $0.key < $1.key }) {
                for signature in signatures where !has(method: name, labels: signature.parameters.map(\.label)) {
                    throw TypeError("\(typeName) doesn't conform to \(protocolName): it needs \(name)(\(signature.parameters.map { ($0.label ?? "_") + ":" }.joined()))")
                }
            }
            for (name, property) in required.declared.properties.sorted(by: { $0.key < $1.key }) where !has(property: name, settable: property.isSettable) {
                throw TypeError("\(typeName) doesn't conform to \(protocolName): it needs the \(property.isSettable ? "settable " : "")property '\(name)'")
            }
            for (name, signatures) in required.declared.staticMethods.sorted(by: { $0.key < $1.key }) {
                for signature in signatures where !has(staticMethod: name, labels: signature.parameters.map(\.label)) {
                    throw TypeError("\(typeName) doesn't conform to \(protocolName): it needs static \(name)(\(signature.parameters.map { ($0.label ?? "_") + ":" }.joined()))")
                }
            }
            for initializer in required.declared.initializers {
                let labels = initializer.parameters.map(\.label)
                guard description.initializers.contains(where: { $0.parameters.map(\.label) == labels }) else {
                    throw TypeError("\(typeName) doesn't conform to \(protocolName): it needs init(\(labels.map { ($0 ?? "_") + ":" }.joined()))")
                }
            }
        }
    }
}
