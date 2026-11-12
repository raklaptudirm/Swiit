import Foundation
import SwiftSyntax
import Synchronization

// The symbols of a type's members: host types, bridged types and types declared in script.

extension Interpreter {
    /// What a bridged Swift member is, as a symbol: a method is a function, anything else a variable.
    /// `bindings` says what the generic parameters of its type are.
    func bridgedSymbol(
        _ member: BridgedMember,
        checker: TypeChecker,
        bindings: [String: TypeAnnotation] = [:],
        isSettable: Bool = false
    ) -> Symbol {
        func throwing() -> Symbol.Throwing {
            member.typedThrows.map { .typed(scriptType(.named($0))) }
                ?? (member.isRethrowing ? .rethrowing : member.isThrowing ? .any : .no)
        }
        func function() -> Symbol.Function {
            Symbol.Function(
                parameters: member.parameters.map {
                    let substituted = checker.substitute($0.type, bindings)
                    var made = Symbol.Parameter(
                        label: $0.label,
                        name: $0.name,
                        type: scriptType(substituted),
                        arity: $0.variadic
                            ? .variadic
                            : $0.defaultValue != nil || $0.externalDefault != nil
                                ? .defaulted(.computed) : .required,
                        documentation: member.parameterDocs[$0.name]
                    )
                    made.annotation = substituted
                    return made
                },
                returns: scriptType(checker.substitute(member.returns, bindings)),
                throwing: throwing(),
                isAsync: member.effect != .sync,
                generics: member.generics
            )
        }
        let kind: Symbol.Kind =
            switch member.kind {
            case .method:
                .method(
                    Symbol.Method(
                        function: function(),
                        isMutating: member.isMutating,
                        isStatic: member.isStatic
                    )
                )
            case .initializer: .initializer(function())
            default:
                .property(
                    Symbol.Property(
                        variable: Symbol.Variable(
                            type: scriptType(checker.substitute(member.returns, bindings)),
                            isSettable: isSettable
                        ),
                        isStatic: member.isStatic,
                        isAsync: member.effect != .sync,
                        throwing: throwing()
                    )
                )
            }
        return Symbol(
            name: member.kind == .initializer ? "init" : member.name,
            summary: member.summary.isEmpty ? nil : member.summary,
            kind: kind,
            attributes: member.attributes
        )
    }

    func parameter(
        _ parameter: Parameter,
        documentation: String? = nil
    ) -> Symbol.Parameter {
        var plain: Value?
        if case .literal(let value)? = parameter.defaultValue { plain = value }
        var made = Symbol.Parameter(
            label: parameter.label,
            name: parameter.name,
            type: parameter.isInout
                ? .inOut(scriptType(parameter.type)) : scriptType(parameter.type),
            arity: parameter.variadic
                ? .variadic
                : parameter.defaultValue != nil || parameter.externalDefault != nil
                    ? .defaulted(plain.map { .value($0) } ?? .computed) : .required,
            documentation: documentation
        )
        made.annotation = parameter.type
        return made
    }

    // swiftlint:disable function_body_length - a long walk over every case; splitting it is item 17 of Docs/agenda.md
    /// What a type has, for `ScriptType.members(named:in:)`: its instance members, its static ones, its
    /// initializers, and the cases of an enum. `rawValues` says the raw values of enums not yet
    /// declared (as `check` reads them), by enum and case.
    func memberSymbols(
        named name: String?,
        of type: TypeAnnotation,
        checker: TypeChecker? = nil,
        rawValues: [String: [String: Value]] = [:]
    ) -> [Symbol] {
        let checker = checker ?? TypeChecker(interpreter: self)
        var found: [Symbol] = []
        func function(
            _ signature: TypeChecker.Signature,
            dropping receiver: Bool = false
        ) -> Symbol.Function {
            var parameters = signature.parameters
            if receiver, parameters.first?.name == "self" { parameters.removeFirst() }
            return Symbol.Function(
                parameters: parameters.map {
                    parameter($0, documentation: signature.documentation?.parameters[$0.name])
                },
                returns: scriptType(signature.returns),
                isThrowing: signature.isThrowing,
                isAsync: signature.effect != .sync,
                generics: signature.generics
            )
        }
        func add(
            _ signature: TypeChecker.Signature,
            dropping receiver: Bool = false,
            isStatic: Bool = false
        ) {
            found.append(
                Symbol(
                    name: signature.name,
                    summary: signature.documentation.map(\.summary)
                        .flatMap { $0.isEmpty ? nil : $0 },
                    kind: .method(
                        Symbol.Method(
                            function: function(signature, dropping: receiver),
                            isMutating: signature.isMutating,
                            isStatic: isStatic
                        )
                    ),
                    attributes: signature.attributes
                )
            )
        }
        // A struct's, enum's or host object's own.
        if let profile = checker.describe(type) {
            for (member, signatures) in profile.declared.methods where name == nil || name == member
            {
                signatures.forEach { add($0) }
            }
            for (member, signatures) in profile.extended.methods where name == nil || name == member
            {
                signatures.forEach { add($0) }
            }
            for (member, property) in profile.declared.properties
            where name == nil || name == member {
                found.append(
                    Symbol(
                        name: member,
                        kind: .property(
                            Symbol.Property(
                                variable: Symbol.Variable(
                                    type: scriptType(property.type),
                                    isSettable: property.isSettable
                                )
                            )
                        )
                    )
                )
            }
            // What belongs to the type itself.
            for set in [profile.declared, profile.extended] {
                for (member, signatures) in set.staticMethods where name == nil || name == member {
                    signatures.forEach { add($0, isStatic: true) }
                }
            }
            for (member, property) in profile.declared.staticProperties
            where name == nil || name == member {
                found.append(
                    Symbol(
                        name: member,
                        kind: .property(
                            Symbol.Property(
                                variable: Symbol.Variable(
                                    type: scriptType(property.type),
                                    isSettable: property.isSettable
                                ),
                                isStatic: true
                            )
                        )
                    )
                )
            }
            if name == nil || name == "init" {
                // A struct with none of its own is made by its memberwise one.
                var initializers = profile.declared.initializers
                if initializers.isEmpty, profile.kind == .structure,
                    let memberwise = profile.memberwise
                {
                    initializers = [memberwise]
                }
                for initializer in initializers {
                    found.append(
                        Symbol(
                            name: "init",
                            kind: .initializer(function(initializer)),
                            attributes: initializer.attributes
                        )
                    )
                }
            }
            if profile.kind == .enumeration {
                let runtime = enumType(named: profile.name)
                for enumCase in profile.cases where name == nil || name == enumCase.name {
                    let raw =
                        rawValues[profile.name]?[enumCase.name]
                        ?? runtime?.case(named: enumCase.name)?.rawValue
                    found.append(
                        Symbol(
                            name: enumCase.name,
                            kind: .enumCase(
                                parameters: enumCase.payload.enumerated()
                                    .map { index, value in
                                        Symbol.Parameter(
                                            label: value.label,
                                            name: value.label ?? String(index),
                                            type: scriptType(value.type)
                                        )
                                    },
                                rawValue: raw
                            )
                        )
                    )
                }
            }
        }
        // A bridged Swift type's.
        if let (bridgedType, bindings) = checker.bridged(type) {
            let settable = Set(
                bridgedType.members.filter { $0.kind == .setter && !$0.isStatic }.map(\.name)
            )
            for member in bridgedType.members
            where member.kind != .setter && (name == nil || name == member.name) {
                found.append(
                    bridgedSymbol(
                        member,
                        checker: checker,
                        bindings: bindings,
                        isSettable: settable.contains(member.name)
                    )
                )
            }
        }
        // What every sequence has: what the host's prelude adds to `Sequence`, which
        // `ScriptType.named(.sequence).members(in:)` lists alone.
        var holder: TypeAnnotation?
        if case .list(let element) = type {
            holder = element
        } else if case .named("Sequence") = type {
            holder = .unknown
        }
        if let element = holder {
            for (member, set) in sequenceMethods where name == nil || name == member {
                for signature in checker.sequenceSignatures(set) {
                    var made = signature
                    made.parameters = made.parameters.map {
                        var p = $0
                        p.type = checker.substitute(p.type, ["Element": element])
                        return p
                    }
                    made.returns = checker.substitute(made.returns, ["Element": element])
                    add(made, dropping: true)
                }
            }
        }
        return found
    }
    // swiftlint:enable function_body_length
}
