import Foundation
import SwiftSyntax
import Synchronization

// Looking types up by identity, and asking what they conform to.

extension Interpreter {
    func typeRef(named name: String) -> TypeRef? {
        let declared = globals(named: name).lazy
            .compactMap { symbol -> TypeRef? in
                if case .type(let type) = symbol { type.typeRef } else { nil }
            }
        return declared.first ?? types.first { $0.name == name }?.typeRef
    }

    func symbol(for typeRef: TypeRef) -> Symbol.Nominal? {
        withMainTask {
            switch typeRef.kind {
            case .declared:
                declaredTypes[typeRef].map { typeSymbol(named: typeRef.name, $0) }
            case .native:
                types.first { $0.typeRef == typeRef }
            }
        }
    }

    /// Whether `typeRef` still means what it did: a declared reference whose declaration is no longer the one
    /// its name means (another `struct Point` was declared since) has gone stale, and a type
    /// written with it is not the type its name means now.
    func isCurrent(_ typeRef: TypeRef) -> Bool {
        guard case .declared = typeRef.kind else { return true }
        guard case .object(let object)? = lookup(typeRef.name)?.value.storage else { return false }
        return (object as? any DeclaredType)?.typeRef == typeRef
    }

    /// A type as the checker reads it, or nil when it names a declared type that has gone stale.
    func annotation(_ type: TypeExpression) -> TypeAnnotation? {
        func current(_ type: TypeExpression) -> Bool {
            switch type {
            case .named(let typeRef, let arguments):
                isCurrent(typeRef) && arguments.allSatisfy(current)
            case .function(let function):
                function.parameters.allSatisfy { current($0.type) } && current(function.returns)
            case .parameter: true
            case .tuple(let elements): elements.allSatisfy { current($0.type) }
            case .metatype(let type): current(type)
            }
        }
        return current(type) ? TypeAnnotation(type) : nil
    }

    /// Every type a script can name, its members to be had from `TypeExpression.members(named:in:)`: those scripts and
    /// the host declare, and Swift's own that the core bridges (`String`, `Array`, `Date`).
    public var types: [Symbol.Nominal] {
        withMainTask {
            let declared = scopes[1].bindings.sorted { $0.key < $1.key }
                .compactMap { name, binding -> Symbol.Nominal? in
                    if case .object(let type as any DeclaredType) = binding.value.storage {
                        return typeSymbol(named: name, type)
                    }
                    return nil
                }
            let bridged = scopes[0].bindings.sorted { $0.key < $1.key }
                .compactMap { name, binding -> Symbol.Nominal? in
                    if case .object(is NativeTypeName) = binding.value.storage {
                        var symbol =
                            Bridge.types[name]?.symbol
                            ?? Symbol.Nominal(name: name, kind: .structure, typeRef: .native(name))
                        symbol.isBuiltin = true
                        return symbol
                    } else {
                        return nil
                    }
                }
            return declared + bridged
        }
    }

    func conforms(_ type: TypeExpression, to proto: TypeRef) -> Bool {
        inCurrentTask {
            guard isCurrent(proto), let annotation = annotation(type) else { return false }
            return TypeChecker(interpreter: self).conforms(annotation, to: proto.name)
        }
    }
}
