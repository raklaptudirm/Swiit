import Foundation
import SwiftSyntax
import Synchronization

// Looking types up by identity, and asking what they conform to.

extension Interpreter {
    func typeID(named name: String) -> Symbol.ID? {
        (globals(named: name) + types.filter { $0.name == name }).lazy.compactMap(\.id).first
    }

    func symbol(for id: Symbol.ID) -> Symbol? {
        withMainTask {
            switch id.kind {
            case .declared:
                declaredTypes[id].map { typeSymbol(named: id.name, $0) }
            case .host:
                types.first { $0.id == id }
            case .parameter:
                nil
            }
        }
    }

    /// Whether `id` still means what it did: a declared ID whose declaration is no longer the one
    /// its name means (another `struct Point` was declared since) has gone stale, and a type
    /// written with it is not the type its name means now.
    func isCurrent(_ id: Symbol.ID) -> Bool {
        guard case .declared = id.kind else { return true }
        guard case .object(let object)? = lookup(id.name)?.value.storage else { return false }
        return (object as? any DeclaredType)?.id == id
    }

    /// A type as the checker reads it, or nil when it names a declared type that has gone stale.
    func annotation(_ type: ScriptType) -> TypeAnnotation? {
        func current(_ type: ScriptType) -> Bool {
            switch type {
            case .named(let id, let arguments): isCurrent(id) && arguments.allSatisfy(current)
            case .function(let parameters, let returns, _, _):
                parameters.allSatisfy(current) && current(returns)
            case .tuple(let elements): elements.allSatisfy { current($0.type) }
            case .metatype(let type), .inOut(let type): current(type)
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
                        var symbol = Symbol(name: name, kind: .structure)
                        symbol.id = .host(name)
                        symbol.isBuiltin = true
                        return symbol
                    } else {
                        return nil
                    }
                }
            return declared + bridged
        }
    }

    func conforms(_ type: ScriptType, to proto: Symbol.ID) -> Bool {
        inCurrentTask {
            guard isCurrent(proto), let annotation = annotation(type) else { return false }
            return TypeChecker(interpreter: self).conforms(annotation, to: proto.name)
        }
    }
}
