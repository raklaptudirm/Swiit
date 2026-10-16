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

    @_spi(Layer) public func structInfo(named name: String) -> StructInfo? {
        if case .structType(let info)? = lookup(name) { return info }
        return nil
    }

    func enumInfo(named name: String) -> EnumInfo? {
        if case .enumType(let info)? = lookup(name) { return info }
        return nil
    }

    @_spi(Layer) public func structInfo(_ type: StructType) -> StructInfo {
        var methods: [String: [Signature]] = [:]
        for (name, set) in type.methods {
            methods[name] = set.candidates.enumerated().map { index, method in
                var signature = signature(method)
                signature.index = index
                return signature
            }
        }
        var info = StructInfo(
            name: type.name, stored: type.stored,
            computed: type.computed.mapValues { $0.returnType ?? .unknown },
            methods: methods,
            initializers: type.initializers?.candidates.enumerated().map { index, initializer in
                Signature(name: initializer.name ?? type.name, parameters: initializer.parameters,
                          returns: initializer.isFailable ? .optional(.named(type.name)) : .named(type.name),
                          isMutating: true, isThrowing: initializer.isThrowing, index: index)
            } ?? [],
            memberwise: Signature(name: type.name, parameters: type.memberwise.parameters, returns: .named(type.name)),
            conformances: type.conformances,
            staticProperties: type.staticProperties,
            staticMethods: type.staticMethods.mapValues { set in
                set.candidates.enumerated().map { index, method in
                    var signature = signature(method)
                    signature.index = index
                    return signature
                }
            }
        )
        info.settable = Set(type.setters.keys)
        for (index, getter) in type.subscriptGetters.enumerated() {
            info.subscripts.append(Signature(name: "subscript", parameters: getter.parameters, returns: getter.returnType ?? .unknown, index: index))
            info.subscriptSettable.append(type.subscriptSetters[index] != nil)
        }
        return info
    }

    func enumInfo(_ type: EnumType) -> EnumInfo {
        let payloads = interpreter.enumPayloadTypes[ObjectIdentifier(type)] ?? [:]
        let cases = type.cases.map { enumCase in
            (enumCase.name, zip(enumCase.labels, payloads[enumCase.name] ?? enumCase.labels.map { _ in .unknown })
                .map { AssociatedValue(label: $0, type: $1) })
        }
        let rawType: TypeAnnotation? = switch type.cases.first?.rawValue {
        case .int?: .int
        case .string?: .string
        case .double?: .double
        default: nil
        }
        var info = EnumInfo(name: type.name, cases: cases, rawType: rawType,
                            conformances: interpreter.enumConformances[ObjectIdentifier(type)] ?? [])
        info.typeParameters = interpreter.enumTypeParameters[ObjectIdentifier(type)] ?? []
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
            info.computed = members.computed.mapValues { $0.returnType ?? .unknown }
            info.methods = signatures(members.methods)
            info.staticProperties = members.staticProperties
            info.staticMethods = signatures(members.staticMethods)
            info.initializers = members.initializers?.candidates.enumerated().map { index, initializer in
                Signature(name: initializer.name ?? type.name, parameters: initializer.parameters,
                          returns: initializer.isFailable ? .optional(.named(type.name)) : .named(type.name),
                          isMutating: true, isThrowing: initializer.isThrowing, index: index)
            } ?? []
        }
        return info
    }
}
