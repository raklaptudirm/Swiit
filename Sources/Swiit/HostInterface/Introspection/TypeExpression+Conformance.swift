import Foundation
import SwiftSyntax
import Synchronization

// Asking whether a type conforms to a protocol, and naming a type by its declaration.

extension TypeExpression {
    /// Whether values of this type have what the protocol asks (`Comparable`, `Hashable`,
    /// `Sequence`, or one a script declares), as the checker reads it. False for a type or a
    /// protocol that is a declaration `interpreter` no longer means by its name.
    public func conforms(to proto: TypeRef, in interpreter: Interpreter) -> Bool {
        interpreter.conforms(self, to: proto)
    }
}

extension Interpreter {
    /// The type as a script's types are named: the names of declared types are their declarations'
    /// references, and what the checker does not know is `Any`.
    func byReference(_ type: TypeExpression) -> TypeExpression {
        switch type {
        case .unknown: return .any
        case .named(let named) where named.reference.kind == .native:
            let reference =
                declaredReference(named: named.reference.name) ?? named.reference
            return .named(reference, named.arguments.map(byReference))
        default: return type.mapping(byReference)
        }
    }

    /// The declaration a name means: a type the script or the host declared, or one the run reserved a
    /// reference for.
    private func declaredReference(named name: String) -> TypeRef? {
        guard case .object(let object)? = lookup(name)?.value.storage else {
            return reservedRefs[name]
        }
        return (object as? any DeclaredType)?.typeRef
    }
}
