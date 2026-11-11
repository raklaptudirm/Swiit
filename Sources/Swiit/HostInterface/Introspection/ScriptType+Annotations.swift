import Foundation
import SwiftSyntax
import Synchronization

// Converting between type annotations and script types, and asking whether a type conforms to a protocol.

extension ScriptType {
    /// The type an annotation names. `declared` says which declaration a name means, for the names
    /// of types a program declares; a name it does not know is a host type's.
    init(_ annotation: TypeAnnotation, declared: (String) -> Symbol.ID? = { _ in nil }) {
        func reference(_ name: String) -> Symbol.ID { declared(name) ?? .host(name) }
        func convert(_ annotation: TypeAnnotation) -> ScriptType {
            ScriptType(annotation, declared: declared)
        }
        self =
            switch annotation {
            case .bool: .bool
            case .int: .int
            case .double: .double
            case .string: .string
            case .function: .callable
            case .record: .named("Record")
            case .named(let name): .named(reference(name))
            case .list(let element): .list(convert(element))
            case .dictionary(let key, let value): .dictionary(convert(key), convert(value))
            case .optional(let wrapped): .optional(convert(wrapped))
            case .generic(let name, let arguments): .named(reference(name), arguments.map(convert))
            case .tuple(let elements):
                .tuple(
                    elements.map { ScriptType.Element(label: $0.label, type: convert($0.type)) }
                )
            case .functionType(let parameters, let returns, let throwing, let effect):
                .function(
                    parameters: parameters.map(convert),
                    returns: convert(returns),
                    isThrowing: throwing,
                    isAsync: effect == .async
                )
            case .keyPath(let root, let value):
                .named(.keyPath, [convert(root), convert(value)])
            // A type parameter (`Element`) is named, and nothing is declared under the name.
            case .parameter(let name): .named(.parameter(name))
            // `Sequence` takes no type argument in Swift, so `Sequence<Element>` is what a
            // parameter of `some Sequence<Element>` is: anything that is a sequence of them.
            case .someSequence(let element): .named(.sequence, [convert(element)])
            case .void: .tuple([])
            case .metatype(let type): .metatype(convert(type))
            default: .any
            }
    }
}

extension ScriptType {
    /// Whether values of this type have what the protocol asks (`Comparable`, `Hashable`,
    /// `Sequence`, or one a script declares), as the checker reads it. False for a type or a
    /// protocol that is a declaration `interpreter` no longer means by its name.
    public func conforms(to proto: Symbol.ID, in interpreter: Interpreter) -> Bool {
        interpreter.conforms(self, to: proto)
    }
}

extension Interpreter {
    /// The type an annotation names, with the names of declared types as their declarations' IDs.
    func scriptType(_ annotation: TypeAnnotation) -> ScriptType {
        ScriptType(annotation) { name in
            guard case .object(let object)? = self.lookup(name)?.value.storage else { return nil }
            return (object as? any DeclaredType)?.id
        }
    }
}
