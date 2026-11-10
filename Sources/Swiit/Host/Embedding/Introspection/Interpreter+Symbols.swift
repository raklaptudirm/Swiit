import Foundation
import SwiftSyntax
import Synchronization

// What a host can ask of the names a script can use: the functions, methods, properties, variables
// and types there are, which overload a call means, and the type of an expression. One lookup for
// everything a name can mean.

extension Interpreter {
    /// What the program and the host have declared for scripts to name: functions, variables and
    /// types, all of them without a `name`, the core's builtins too. `ScriptType.members(named:in:)`
    /// says what a type has.
    public func globals(named name: String? = nil) -> [Symbol] {
        withMainTask { globalSymbols(named: name) }
    }

    func members(of type: ScriptType, named name: String?) -> [Symbol] {
        // A type written as a value has what belongs to the type itself.
        if case .metatype(let instance) = type {
            return members(of: instance, named: name)
                .filter {
                    switch $0.kind {
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
                let generic = Bridge.types[typeName]?.genericParameters,
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
            return candidates.map { symbol(of: $0, named: name) }
        case .object(let type as any DeclaredType): return [typeSymbol(named: name, type)]
        default:
            let checker = TypeChecker(interpreter: self)
            return [
                Symbol(
                    name: name,
                    kind: .variable(
                        Symbol.Variable(
                            type: scriptType(checker.type(of: binding.value)),
                            isSettable: binding.mutable
                        )
                    )
                )
            ]
        }
    }

    /// A declared type as a symbol.
    func typeSymbol(named name: String, _ type: any DeclaredType) -> Symbol {
        let kind: Symbol.Kind =
            switch type {
            case is StructType: .structure
            case is Value.EnumCase.Enumeration: .enumeration
            case let type as ClassType: type.isActor ? .actor : .class
            default: .protocol
            }
        var symbol = Symbol(name: name, kind: kind)
        symbol.id = type.id
        return symbol
    }

    /// What a function is, as a symbol: `name` when it has none of its own.
    func symbol(of function: Function, named name: String) -> Symbol {
        var symbol = Symbol(
            name: function.name ?? name,
            summary: function.documentation.map(\.summary)
                .flatMap { $0.isEmpty ? nil : $0 },
            kind: .function(
                Symbol.Function(
                    parameters: function.parameters.map {
                        parameter(
                            $0,
                            documentation: function.documentation?.parameters[$0.name]
                        )
                    },
                    returns: function.returnType.map(scriptType) ?? .void,
                    isThrowing: function.isThrowing,
                    isAsync: function.effect != .sync,
                    generics: function.generics
                )
            ),
            attributes: function.attributes
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

    func declaredSymbols(of name: String, _ symbol: TypeChecker.Symbol) -> [Symbol] {
        switch symbol {
        case .functions(let signatures):
            return signatures.map { signature in
                Symbol(
                    name: signature.name,
                    kind: .function(
                        Symbol.Function(
                            parameters: signature.parameters.map { parameter($0) },
                            returns: scriptType(signature.returns),
                            isThrowing: signature.isThrowing,
                            isAsync: signature.effect != .sync
                        )
                    )
                )
            }
        case .structType: return [Symbol(name: name, kind: .structure)]
        case .enumType: return [Symbol(name: name, kind: .enumeration)]
        case .protocolType: return [Symbol(name: name, kind: .protocol)]
        case .variable(let type, let mutable):
            return [
                Symbol(
                    name: name,
                    kind: .variable(
                        Symbol.Variable(type: ScriptType(type), isSettable: mutable)
                    )
                )
            ]
        case .swiftType, .asyncLet: return []
        }
    }
}
