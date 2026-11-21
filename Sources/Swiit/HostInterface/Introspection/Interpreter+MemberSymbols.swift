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
        let summary = member.summary.isEmpty ? nil : member.summary
        func throwing() -> Symbol.Throwing {
            member.typedThrows.map { .typed(typeExpression(.named($0))) }
                ?? (member.isRethrowing ? .rethrowing : member.isThrowing ? .any : .no)
        }
        func signature() -> Symbol.Signature {
            Symbol.Signature(
                parameters: member.parameters.map {
                    let substituted = checker.substitute($0.type, bindings)
                    var made = Symbol.Parameter(
                        label: $0.label,
                        name: $0.name,
                        type: typeExpression(substituted),
                        arity: $0.variadic
                            ? .variadic
                            : $0.defaultValue != nil || $0.externalDefault != nil
                                ? .defaulted(.computed) : .required,
                        documentation: member.parameterDocs[$0.name]
                    )
                    made.annotation = substituted
                    return made
                },
                returns: typeExpression(checker.substitute(member.returns, bindings)),
                throwing: throwing(),
                isAsync: member.effect != .sync,
                generics: member.generics
            )
        }
        switch member.kind {
        case .method:
            return .method(
                Symbol.Method(
                    name: member.name,
                    summary: summary,
                    attributes: member.attributes,
                    signature: signature(),
                    isMutating: member.isMutating,
                    isStatic: member.isStatic
                )
            )
        case .initializer:
            return .initializer(
                Symbol.Initializer(
                    summary: summary,
                    attributes: member.attributes,
                    signature: signature()
                )
            )
        default:
            return .property(
                Symbol.Property(
                    name: member.name,
                    summary: summary,
                    attributes: member.attributes,
                    type: typeExpression(checker.substitute(member.returns, bindings)),
                    isSettable: isSettable,
                    isStatic: member.isStatic,
                    isAsync: member.effect != .sync,
                    throwing: throwing()
                )
            )
        }
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
            type: typeExpression(parameter.type),
            isInout: parameter.isInout,
            arity: parameter.variadic
                ? .variadic
                : parameter.defaultValue != nil || parameter.externalDefault != nil
                    ? .defaulted(plain.map { .value($0) } ?? .computed) : .required,
            documentation: documentation
        )
        made.annotation = parameter.type
        return made
    }

    /// What a type has, for `TypeExpression.members(named:in:)`: its instance members, its static ones, its
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
        // A struct's, enum's or host object's own.
        if let profile = checker.describe(type) {
            found += declaredMemberSymbols(of: profile, named: name, rawValues: rawValues)
        }
        // A bridged Swift type's.
        if let (bridgedType, bindings) = checker.bridged(type) {
            found += bridgedMemberSymbols(
                of: bridgedType,
                bindings: bindings,
                named: name,
                checker: checker
            )
        }
        // What every sequence has: what the host's prelude adds to `Sequence`, which
        // `TypeExpression.named(.sequence).members(in:)` lists alone.
        var holder: TypeAnnotation?
        if case .list(let element) = type {
            holder = element
        } else if case .named("Sequence") = type {
            holder = .unknown
        }
        if let element = holder {
            found += sequenceMemberSymbols(of: element, named: name, checker: checker)
        }
        return found
    }

    /// A signature the checker wrote, as a symbol's; without `self` for a method of a value.
    private func signature(
        _ signature: TypeChecker.Signature,
        dropping receiver: Bool = false
    ) -> Symbol.Signature {
        var parameters = signature.parameters
        if receiver, parameters.first?.name == "self" { parameters.removeFirst() }
        return Symbol.Signature(
            parameters: parameters.map {
                parameter($0, documentation: signature.documentation?.parameters[$0.name])
            },
            returns: typeExpression(signature.returns),
            isThrowing: signature.isThrowing,
            isAsync: signature.effect != .sync,
            generics: signature.generics
        )
    }

    private func methodSymbol(
        _ method: TypeChecker.Signature,
        dropping receiver: Bool = false,
        isStatic: Bool = false
    ) -> Symbol {
        .method(
            Symbol.Method(
                name: method.name,
                summary: method.documentation.map(\.summary).flatMap { $0.isEmpty ? nil : $0 },
                attributes: method.attributes,
                signature: signature(method, dropping: receiver),
                isMutating: method.isMutating,
                isStatic: isStatic
            )
        )
    }

    /// What a struct, an enum or a host object declares, and what extensions add.
    private func declaredMemberSymbols(
        of profile: TypeProfile,
        named name: String?,
        rawValues: [String: [String: Value]]
    ) -> [Symbol] {
        func wanted(_ member: String) -> Bool { name == nil || name == member }
        var found: [Symbol] = []
        for set in [profile.declared, profile.extended] {
            for (member, signatures) in set.methods where wanted(member) {
                found += signatures.map { methodSymbol($0) }
            }
        }
        for (member, property) in profile.declared.properties where wanted(member) {
            found.append(
                .property(
                    Symbol.Property(
                        name: member,
                        type: typeExpression(property.type),
                        isSettable: property.isSettable
                    )
                )
            )
        }
        // What belongs to the type itself.
        for set in [profile.declared, profile.extended] {
            for (member, signatures) in set.staticMethods where wanted(member) {
                found += signatures.map { methodSymbol($0, isStatic: true) }
            }
        }
        for (member, property) in profile.declared.staticProperties where wanted(member) {
            found.append(
                .property(
                    Symbol.Property(
                        name: member,
                        type: typeExpression(property.type),
                        isSettable: property.isSettable,
                        isStatic: true
                    )
                )
            )
        }
        if wanted("init") { found += initializerSymbols(of: profile) }
        for member in profile.associatedTypes where wanted(member) {
            found.append(
                .associatedType(
                    Symbol.AssociatedType(name: member, role: .requirement(constraints: []))
                )
            )
        }
        if profile.kind == .enumeration {
            found += caseSymbols(of: profile, named: name, rawValues: rawValues)
        }
        return found
    }

    private func initializerSymbols(of profile: TypeProfile) -> [Symbol] {
        // A struct with none of its own is made by its memberwise one.
        var initializers = profile.declared.initializers
        if initializers.isEmpty, profile.kind == .structure, let memberwise = profile.memberwise {
            initializers = [memberwise]
        }
        return initializers.map { initializer in
            .initializer(
                Symbol.Initializer(
                    attributes: initializer.attributes,
                    signature: signature(initializer)
                )
            )
        }
    }

    private func caseSymbols(
        of profile: TypeProfile,
        named name: String?,
        rawValues: [String: [String: Value]]
    ) -> [Symbol] {
        let runtime = enumType(named: profile.name)
        return profile.cases.filter { name == nil || name == $0.name }
            .map { enumCase in
                let raw =
                    rawValues[profile.name]?[enumCase.name]
                    ?? runtime?.case(named: enumCase.name)?.rawValue
                return .enumCase(
                    Symbol.EnumCase(
                        name: enumCase.name,
                        payload: enumCase.payload.map {
                            TypeExpression.Tuple.Element(
                                label: $0.label,
                                type: typeExpression($0.type)
                            )
                        },
                        rawValue: raw
                    )
                )
            }
    }

    /// What a bridged Swift type has, with its generic parameters bound as `bindings` says.
    private func bridgedMemberSymbols(
        of bridgedType: ImplementedType,
        bindings: [String: TypeAnnotation],
        named name: String?,
        checker: TypeChecker
    ) -> [Symbol] {
        var found: [Symbol] = []
        let settable = Set(
            bridgedType.lowered.filter { $0.kind == .setter && !$0.isStatic }.map(\.name)
        )
        for member in bridgedType.lowered
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
        for member in bridgedType.members where name == nil || name == member.name {
            if case .associatedType = member.symbol { found.append(member.symbol) }
        }
        return found
    }

    /// The methods every sequence of `element` has.
    private func sequenceMemberSymbols(
        of element: TypeAnnotation,
        named name: String?,
        checker: TypeChecker
    ) -> [Symbol] {
        var found: [Symbol] = []
        for (member, set) in sequenceMethods where name == nil || name == member {
            for var made in checker.sequenceSignatures(set) {
                made.parameters = made.parameters.map {
                    var p = $0
                    p.type = checker.substitute(p.type, ["Element": element])
                    return p
                }
                made.returns = checker.substitute(made.returns, ["Element": element])
                found.append(methodSymbol(made, dropping: true))
            }
        }
        return found
    }
}
