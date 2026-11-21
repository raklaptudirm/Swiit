import Foundation
import SwiftSyntax
import Synchronization

// What a host can ask of the names a script can use: the functions, methods, properties, variables
// and types there are, which overload a call means, and the type of an expression. One lookup for
// everything a name can mean.

extension Interpreter {
    /// Every function, variable and type a script can name: those the program and the host declared, and
    /// the core's builtins. With `name`, only the symbols of that name. What a type has is read with
    /// `TypeExpression.members(named:in:)`.
    public func globals(named name: String? = nil) -> [Symbol] {
        withMainTask { globalSymbols(named: name) }
    }

    func members(of type: TypeExpression, named name: String?) -> [Symbol] {
        // A type written as a value has what belongs to the type itself.
        if case .metatype(let metatype) = type {
            return members(of: metatype.instance, named: name)
                .filter {
                    switch $0 {
                    case .method(let method): method.isStatic
                    case .property(let property): property.isStatic
                    case .initializer, .enumCase: true
                    default: false
                    }
                }
        }
        return withMainTask {
            guard var annotation = self.annotation(type) else { return [] }
            // A generic Swift type by its bare name has members whatever it holds: `Array`, `Set`.
            if case .named(let typeName) = annotation,
                let generic = bridged[typeName]?.genericParameters,
                !generic.isEmpty
            {
                annotation = .generic(typeName, generic.map { _ in .unknown })
            }
            return memberSymbols(named: name, of: annotation)
        }
    }

    private func globalSymbols(named name: String?) -> [Symbol] {
        if let name {
            return lookup(name).map { symbols(of: name, binding: $0) } ?? []
        }
        // What was declared, then the core's builtins it doesn't shadow.
        let declared = scopes[1].bindings
        let core = scopes[0].bindings.filter { declared[$0.key] == nil }
        return (declared.sorted { $0.key < $1.key } + core.sorted { $0.key < $1.key })
            .flatMap { symbols(of: $0.key, binding: $0.value) }
    }

    func symbols(of name: String, binding: Binding) -> [Symbol] {
        switch binding.value.storage {
        case .function(let callable):
            let candidates =
                (callable as? OverloadSet)?.candidates ?? (callable as? Function).map { [$0] } ?? []
            return candidates.map { .function(symbol(of: $0, named: name)) }
        case .object(let type as any DeclaredType): return [.type(typeSymbol(named: name, type))]
        default:
            let checker = TypeChecker(interpreter: self)
            return [
                .variable(
                    Symbol.Variable(
                        name: name,
                        type: typeExpression(checker.type(of: binding.value)),
                        isSettable: binding.mutable
                    )
                )
            ]
        }
    }

    /// A declared type as a symbol, with its kind, reference, generic parameters and conformances,
    /// those extensions gave it too. Whichever way a type's symbol is asked for gives this one.
    func typeSymbol(named name: String, _ type: any DeclaredType) -> Symbol.Nominal {
        var symbol: Symbol.Nominal
        var declared: [String] = []
        if let record = record(of: type) {
            symbol = record.symbol
            declared = record.declaredConformances
        } else {
            // An enum a host offers has no record, only its cases.
            symbol = Symbol.Nominal(name: name, kind: .enumeration, typeRef: type.typeRef)
            declared = (type as? Value.EnumCase.Enumeration)?.conformances ?? []
        }
        for protocolName in conformances(ofTypeNamed: name, declared: declared) {
            symbol.conformances[protocolRef(named: protocolName)] = []
        }
        return symbol
    }

    /// The reference to a protocol a type names: the script's declaration of it, or the Swift one
    /// of that name.
    private func protocolRef(named name: String) -> TypeRef {
        protocolType(named: name)?.typeRef ?? TypeRef(nativeType: name)
    }

    /// What a function is, as a symbol: `name` when it has none of its own.
    func symbol(of function: Function, named name: String) -> Symbol.Function {
        var symbol = Symbol.Function(
            name: function.name ?? name,
            summary: function.documentation.map(\.summary)
                .flatMap { $0.isEmpty ? nil : $0 },
            attributes: function.attributes,
            signature: Symbol.Signature(
                parameters: function.parameters.map {
                    parameter(
                        $0,
                        documentation: function.documentation?.parameters[$0.name]
                    )
                },
                returns: function.returnType.map(typeExpression) ?? .void,
                isThrowing: function.isThrowing,
                isAsync: function.effect != .sync,
                generics: function.generics
            )
        )
        symbol.isBuiltin = function.isBuiltin
        return symbol
    }

    /// The raw values an enum's cases have: the ones written as literals, and the ones Swift gives
    /// the rest (`0, 1, 2…` for an `Int`, the case's name for a `String`).
    static func rawValues(of decl: EnumDecl) -> [String: Value] {
        guard let rawType = decl.rawType else { return [:] }
        var values: [String: Value] = [:]
        var next = 0
        for enumCase in decl.cases {
            var raw: Value?
            if case .literal(let value)? = enumCase.rawValue {
                raw = value
            } else if enumCase.rawValue == nil {
                switch rawType {
                case .int: raw = .int(next)
                case .string: raw = .string(enumCase.name)
                default: break
                }
            }
            if let raw {
                values[enumCase.name] = raw
                if case .int(let n) = raw.storage { next = n + 1 }
            }
        }
        return values
    }

    func declaredSymbols(of name: String, _ symbol: TypeChecker.ScopeEntry) -> [Symbol] {
        switch symbol {
        case .functions(let signatures):
            return signatures.map { signature in
                .function(
                    Symbol.Function(
                        name: signature.name,
                        signature: Symbol.Signature(
                            parameters: signature.parameters.map { parameter($0) },
                            returns: typeExpression(signature.returns),
                            isThrowing: signature.isThrowing,
                            isAsync: signature.effect != .sync
                        )
                    )
                )
            }
        // A type the source being checked declares: nothing is declared under its reference yet.
        case .structType:
            return [.type(Symbol.Nominal(name: name, kind: .structure, typeRef: .declare(name)))]
        case .enumType:
            return [.type(Symbol.Nominal(name: name, kind: .enumeration, typeRef: .declare(name)))]
        case .protocolType:
            return [.type(Symbol.Nominal(name: name, kind: .protocol, typeRef: .declare(name)))]
        case .variable(let type, let mutable):
            return [
                .variable(
                    Symbol.Variable(name: name, type: TypeExpression(type), isSettable: mutable)
                )
            ]
        case .swiftType, .asyncLet: return []
        }
    }
}
