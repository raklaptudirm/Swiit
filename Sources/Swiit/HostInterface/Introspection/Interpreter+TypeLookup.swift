import Foundation
import SwiftSyntax
import Synchronization

// Looking types up by identity, and asking what they conform to.

extension Interpreter {
    func typeRef(named name: String) -> TypeRef? {
        (globals(named: name) + types.filter { $0.name == name }).lazy.compactMap(\.typeRef).first
    }

    func symbol(for typeRef: TypeRef) -> Symbol? {
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
    func annotation(_ type: ScriptType) -> TypeAnnotation? {
        func current(_ type: ScriptType) -> Bool {
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

    /// Every type a script can name, its members to be had from `ScriptType.members(named:in:)`: those scripts and
    /// the host declare, and Swift's own that the core bridges (`String`, `Array`, `Date`).
    public var types: [Symbol] {
        withMainTask {
            let declared = scopes[1].bindings.sorted { $0.key < $1.key }
                .flatMap { symbols(of: $0.key, binding: $0.value) }
                .filter {
                    if $0.isType { true } else { false }
                }
            let bridged = scopes[0].bindings.sorted { $0.key < $1.key }
                .compactMap { name, binding -> Symbol? in
                    if case .object(is BridgedTypeName) = binding.value.storage {
                        var symbol =
                            Bridge.types[name]?.symbol
                            ?? Symbol(name: name, kind: .type(.structure))
                        symbol.typeRef = .native(name)
                        symbol.isBuiltin = true
                        return symbol
                    } else {
                        return nil
                    }
                }
            return declared + bridged
        }
    }

    func conforms(_ type: ScriptType, to proto: TypeRef) -> Bool {
        inCurrentTask {
            guard isCurrent(proto), let annotation = annotation(type) else { return false }
            return TypeChecker(interpreter: self).conforms(annotation, to: proto.name)
        }
    }
}
