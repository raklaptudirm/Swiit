import Foundation
import SwishKit

extension TypeChecker {
    // MARK: Names

    @_spi(Shell) public func lookup(_ name: String) -> Symbol? {
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
        case .object(let object as DynamicObject):
            return .variable(.named(object.typeName), mutable: false)
        case .object(let object as CheckedObject) where object.isModule:
            return .module
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

    @_spi(Shell) public func signature(_ function: Function) -> Signature {
        // A builtin that hasn't declared its result isn't known; a Swish
        // function without `->` returns nothing.
        var returns = function.returnType ?? (function.isBuiltin ? .unknown : .void)
        if function.plugin != nil && returns == .any { returns = .unknown }
        return Signature(name: function.name ?? "closure", parameters: function.parameters, returns: returns,
                         isMutating: function.isMutating, isThrowing: function.isThrowing,
                         isRethrowing: function.isRethrowing, generics: function.generics)
    }

    @_spi(Shell) public func structInfo(named name: String) -> StructInfo? {
        if case .structType(let info)? = lookup(name) { return info }
        return nil
    }

    @_spi(Shell) public func enumInfo(named name: String) -> EnumInfo? {
        if case .enumType(let info)? = lookup(name) { return info }
        return nil
    }

    @_spi(Shell) public func structInfo(_ type: StructType) -> StructInfo {
        var methods: [String: [Signature]] = [:]
        for (name, set) in type.methods {
            methods[name] = set.candidates.enumerated().map { index, method in
                var signature = signature(method)
                signature.index = index
                return signature
            }
        }
        return StructInfo(
            name: type.name, stored: type.stored,
            computed: type.computed.mapValues { $0.returnType ?? .unknown },
            methods: methods,
            initializers: type.initializers?.candidates.enumerated().map { index, initializer in
                Signature(name: initializer.name ?? type.name, parameters: initializer.parameters, returns: .named(type.name),
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
    }

    @_spi(Shell) public func enumInfo(_ type: EnumType) -> EnumInfo {
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
        return EnumInfo(name: type.name, cases: cases, rawType: rawType,
                        conformances: interpreter.enumConformances[ObjectIdentifier(type)] ?? [])
    }
}
