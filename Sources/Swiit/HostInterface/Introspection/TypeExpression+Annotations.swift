import Foundation
import SwiftSyntax
import Synchronization

// Converting between type annotations and script types, and asking whether a type conforms to a protocol.

extension TypeExpression {
    /// The type an annotation names. `declared` says which declaration a name means, for the names
    /// of types a program declares; a name it does not know is a host type's.
    init(_ annotation: TypeAnnotation, declared: (String) -> TypeRef? = { _ in nil }) {
        func reference(_ name: String) -> TypeRef { declared(name) ?? .native(name) }
        func convert(_ annotation: TypeAnnotation) -> TypeExpression {
            TypeExpression(annotation, declared: declared)
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
                    TypeExpression.Tuple(
                        elements.map {
                            TypeExpression.Tuple.Element(label: $0.label, type: convert($0.type))
                        }
                    )
                )
            case .functionType(let parameters, let returns, let throwing, let effect):
                .function(
                    TypeExpression.FunctionType(
                        parameters: parameters.map { parameter in
                            if case .inOut(let inner) = parameter {
                                TypeExpression.FunctionType.Parameter(convert(inner), isInout: true)
                            } else {
                                TypeExpression.FunctionType.Parameter(convert(parameter))
                            }
                        },
                        returns: convert(returns),
                        throwing: throwing ? .any : .no,
                        isAsync: effect == .async
                    )
                )
            case .keyPath(let root, let value):
                .named(.keyPath, [convert(root), convert(value)])
            case .parameter(let name): .parameter(name)
            // `Sequence` takes no type argument in Swift, so `Sequence<Element>` is what a
            // parameter of `some Sequence<Element>` is: anything that is a sequence of them.
            case .someSequence(let element): .named(.sequence, [convert(element)])
            case .void: .tuple([])
            case .metatype(let type): .metatype(.init(convert(type)))
            case .inOut(let type): convert(type)
            default: .any
            }
    }
}

extension TypeExpression {
    /// Whether values of this type have what the protocol asks (`Comparable`, `Hashable`,
    /// `Sequence`, or one a script declares), as the checker reads it. False for a type or a
    /// protocol that is a declaration `interpreter` no longer means by its name.
    public func conforms(to proto: TypeRef, in interpreter: Interpreter) -> Bool {
        interpreter.conforms(self, to: proto)
    }
}

extension Interpreter {
    /// The type an annotation names, with the names of declared types as their declarations' IDs.
    func typeExpression(_ annotation: TypeAnnotation) -> TypeExpression {
        TypeExpression(annotation) { name in
            guard case .object(let object)? = self.lookup(name)?.value.storage else {
                return self.reservedRefs[name]
            }
            return (object as? any DeclaredType)?.typeRef
        }
    }
}
