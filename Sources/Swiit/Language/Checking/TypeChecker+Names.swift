import Foundation
import SwiitKit

extension TypeChecker {
    // MARK: Names

    @_spi(Layer) public func lookup(_ name: String) -> Symbol? {
        for scope in scopes.reversed() {
            if let symbol = scope[name] { return symbol }
        }
        guard let binding = interpreter.lookup(name) else { return nil }
        if binding.isComputed { return .variable(interpreter.staticTypes[name] ?? .unknown, mutable: false) }
        switch binding.value {
        case .object(let type as StructType):
            return .structType(structInfo(type))
        case .object(let type as EnumType):
            return .enumType(enumInfo(type))
        case .object(let type as ProtocolType):
            return .protocolType(protocolInfo(type.declaration))
        case .object(let object as DynamicObject):
            return .variable(.named(object.typeName), mutable: false)
        case .object(let type as BridgedTypeName):
            return .swiftType(type.name)
        case .function(let set as OverloadSet):
            return .functions(set.candidates.enumerated().map { index, function in
                var signature = signature(function)
                signature.index = index
                return signature
            })
        default:
            return .variable(interpreter.staticTypes[name] ?? type(of: binding.value), mutable: binding.mutable)
        }
    }

    func signature(_ function: Function) -> Signature {
        // A builtin that hasn't declared its result isn't known; a Swiit
        // function without `->` returns nothing.
        let returns = function.returnType ?? (function.isBuiltin ? .unknown : .void)
        var made = Signature(name: function.name ?? "closure", parameters: function.parameters, returns: returns,
                             isMutating: function.isMutating, isThrowing: function.isThrowing,
                             isRethrowing: function.isRethrowing, effect: function.effect, generics: function.generics)
        made.typeParameters = function.typeParameters
        made.flattensResult = function.flattensResult
        return made
    }

    @_spi(Layer) public func structInfo(named name: String) -> TypeProfile? {
        if case .structType(let info)? = lookup(name) { return info }
        return nil
    }

    func enumInfo(named name: String) -> TypeProfile? {
        if case .enumType(let info)? = lookup(name) { return info }
        return nil
    }

    @_spi(Layer) public func structInfo(_ type: StructType) -> TypeProfile {
        func signatures(_ sets: [String: OverloadSet]) -> [String: [Signature]] {
            sets.mapValues { set in
                set.candidates.enumerated().map { index, method in
                    var signature = signature(method)
                    signature.index = index
                    return signature
                }
            }
        }
        var profile = TypeProfile(name: type.name, kind: .structure)
        profile.conformances = type.conformances
        profile.memberwise = Signature(name: type.name, parameters: type.memberwise.parameters, returns: .named(type.name))
        for property in type.stored { profile.declared.properties[property.name] = MemberProperty(type: property.type ?? .unknown, isSettable: property.mutable, stored: property) }
        for (name, getter) in type.computed where profile.declared.properties[name] == nil {
            profile.declared.properties[name] = MemberProperty(type: getter.returnType ?? .unknown, isSettable: type.setters[name] != nil, stored: nil)
        }
        profile.declared.methods = signatures(type.methods)
        profile.declared.initializers = type.initializers?.candidates.enumerated().map { index, initializer in
            Signature(name: initializer.name ?? type.name, parameters: initializer.parameters,
                      returns: initializer.isFailable ? .optional(.named(type.name)) : .named(type.name),
                      isMutating: true, isThrowing: initializer.isThrowing, index: index)
        } ?? []
        for property in type.staticProperties { profile.declared.staticProperties[property.name] = MemberProperty(staticDeclaration: property) }
        profile.declared.staticMethods = signatures(type.staticMethods)
        for (index, getter) in type.subscriptGetters.enumerated() {
            profile.subscripts.append(Signature(name: "subscript", parameters: getter.parameters, returns: getter.returnType ?? .unknown, index: index))
            profile.subscriptSettable.append(type.subscriptSetters[index] != nil)
        }
        return profile
    }

    func enumInfo(_ type: EnumType) -> TypeProfile {
        let payloads = interpreter.enumPayloadTypes[ObjectIdentifier(type)] ?? [:]
        var profile = TypeProfile(name: type.name, kind: .enumeration)
        profile.cases = type.cases.map { enumCase in
            (enumCase.name, zip(enumCase.labels, payloads[enumCase.name] ?? enumCase.labels.map { _ in .unknown })
                .map { AssociatedValue(label: $0, type: $1) })
        }
        profile.rawType = switch type.cases.first?.rawValue {
        case .int?: .int
        case .string?: .string
        case .double?: .double
        default: nil
        }
        profile.conformances = interpreter.enumConformances[ObjectIdentifier(type)] ?? []
        profile.typeParameters = interpreter.enumTypeParameters[ObjectIdentifier(type)] ?? []
        if let members = interpreter.enumMembers[ObjectIdentifier(type)] {
            func signatures(_ sets: [String: OverloadSet]) -> [String: [Signature]] {
                sets.mapValues { set in
                    set.candidates.enumerated().map { index, method in
                        var signature = signature(method)
                        signature.index = index
                        return signature
                    }
                }
            }
            for (name, function) in members.computed {
                profile.declared.properties[name] = MemberProperty(type: function.returnType ?? .unknown, isSettable: false, stored: nil)
            }
            profile.declared.methods = signatures(members.methods)
            for property in members.staticProperties { profile.declared.staticProperties[property.name] = MemberProperty(staticDeclaration: property) }
            profile.declared.staticMethods = signatures(members.staticMethods)
            profile.declared.initializers = members.initializers?.candidates.enumerated().map { index, initializer in
                Signature(name: initializer.name ?? type.name, parameters: initializer.parameters,
                          returns: initializer.isFailable ? .optional(.named(type.name)) : .named(type.name),
                          isMutating: true, isThrowing: initializer.isThrowing, index: index)
            } ?? []
        }
        profile.addSynthesizedEnumMembers()
        return profile
    }
}
