import SwiftSyntax

// Lowering type annotations: names, optionals, tuples, functions and generics.

extension Lowering {
    func type(_ node: TypeSyntax) throws -> TypeAnnotation {
        if let identifier = node.as(IdentifierTypeSyntax.self) {
            return try type(named: identifier)
        }

        // A nested type: `FilePath.Component`.
        if let member = node.as(MemberTypeSyntax.self), member.genericArgumentClause == nil,
            let base = dottedName(member.baseType)
        {
            let name = base + "." + member.name.text
            if let spelled = TypeAnnotation.spelled(name) { return spelled }
            guard declaredTypes.contains(name) || bound[name] == .type else {
                throw SyntaxError("unknown type '\(name)'")
            }
            return .named(name)
        }
        if let array = node.as(ArrayTypeSyntax.self) { return .list(try type(array.element)) }
        if let dictionary = node.as(DictionaryTypeSyntax.self) {
            return .dictionary(try type(dictionary.key), try type(dictionary.value))
        }
        if let optional = node.as(OptionalTypeSyntax.self) {
            return .optional(try type(optional.wrappedType))
        }
        // `Foo!`: an optional that is taken to hold a value.
        if let optional = node.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
            return .optional(try type(optional.wrappedType))
        }
        // `T.Type`, `Any.Type`: the type itself as a value.
        if let metatype = node.as(MetatypeTypeSyntax.self) {
            return .metatype(try type(metatype.baseType))
        }
        if let tuple = node.as(TupleTypeSyntax.self) { return try type(of: tuple) }
        if let function = node.as(FunctionTypeSyntax.self) { return try type(of: function) }
        if let attributed = node.as(AttributedTypeSyntax.self) {
            return try type(attributed.baseType)
        }

        // `any Shape`, `some Shape`: the protocol's type; `A & B`, the first, which the others add
        // to.
        if let existential = node.as(SomeOrAnyTypeSyntax.self) {
            return try type(existential.constraint)
        }
        if let composition = node.as(CompositionTypeSyntax.self) {
            return try type(of: composition)
        }
        throw unsupported("this type", node)
    }

    /// A type written as a name: a parameter, an alias, a generic's arguments, a declared type.
    private func type(named identifier: IdentifierTypeSyntax) throws -> TypeAnnotation {
        let name = identifier.name.text
        if typeParameters.contains(name) { return .parameter(name) }
        if Lowering.fixedWidthIntegers.contains(name), identifier.genericArgumentClause == nil,
            bound[name] == nil,
            !declaredTypes.contains(name)
        {
            return .int
        }
        if let target = Lowering.swiftAliases[name], bound[name] == nil,
            !declaredTypes.contains(name)
        {
            return .named(target)
        }
        let isGenericEnum =
            facts.genericEnums.contains(nestedNames[name] ?? name)
            || name == "Result" && declaredTypes.contains("Result") == false
                && bound["Result"] == .type
        if let clause = identifier.genericArgumentClause, isGenericEnum {
            let arguments = try clause.arguments.map { argument -> TypeAnnotation in
                guard case .type(let written) = argument.argument else {
                    throw unsupported("this generic argument", argument)
                }
                return try type(written)
            }
            return .generic(nestedNames[name] ?? name, arguments)
        }
        if identifier.genericArgumentClause != nil, !facts.protocols.contains(name),
            declaredTypes.contains(nestedNames[name] ?? name)
                || bound[name] == .type && TypeAnnotation.spelled(name) == nil
                    && Bridge.current[name] == nil
        {
            // A generic type of the program's own: its arguments only say what it holds.
            return .named(nestedNames[name] ?? name)
        }
        if let clause = identifier.genericArgumentClause {
            let arguments = try clause.arguments.map { argument -> TypeAnnotation in
                guard case .type(let written) = argument.argument else {
                    throw unsupported("this generic argument", argument)
                }
                return try type(written)
            }
            if name == "KeyPath", arguments.count == 2 {
                return .keyPath(arguments[0], arguments[1])
            }
            return TypeAnnotation.spelled(name, arguments) ?? .generic(name, arguments)
        }
        if let alias = aliases[name] { return alias }
        if name == "Self", let current = currentType { return .named(current) }
        if name == "AnyObject", bound[name] == nil, !declaredTypes.contains(name) {
            return .any
        }
        if typeParameters.contains(name) { return .parameter(name) }
        if let nested = nestedNames[name] { return .named(nested) }
        if let spelled = TypeAnnotation.spelled(name) { return spelled }
        if name == "Void" { return .void }
        // `any Collection`, `any Numeric`: Swift's protocols as types hold any value.
        if Lowering.protocols.contains(name), bound[name] != .type,
            !declaredTypes.contains(name)
        {
            return .any
        }
        guard declaredTypes.contains(name) || bound[name] == .type else {
            throw SyntaxError("unknown type '\(name)'")
        }
        return .named(name)
    }

    private func type(of tuple: TupleTypeSyntax) throws -> TypeAnnotation {
        if tuple.elements.isEmpty { return .void }
        if tuple.elements.count == 1, let only = tuple.elements.first, only.firstName == nil {
            return try type(only.type)
        }
        return .tuple(
            try tuple.elements.map {
                TypeAnnotation.TupleElement(label: $0.firstName?.text, type: try type($0.type))
            }
        )
    }

    private func type(of function: FunctionTypeSyntax) throws -> TypeAnnotation {
        let throwing = function.effectSpecifiers?.throwsClause != nil
        let effect: Effect = function.effectSpecifiers?.asyncSpecifier != nil ? .async : .sync
        return .functionType(
            try function.parameters.map { parameter -> TypeAnnotation in
                let isInout =
                    parameter.type.as(AttributedTypeSyntax.self)?.specifiers
                    .contains { specifier in
                        if case .simpleTypeSpecifier(let simple) = specifier {
                            return simple.specifier.tokenKind == .keyword(.inout)
                        }
                        return false
                    } ?? false
                let lowered = try type(parameter.type)
                return isInout ? .inOut(lowered) : lowered
            },
            try type(function.returnClause.type),
            throws: throwing,
            async: effect
        )
    }

    private func type(of composition: CompositionTypeSyntax) throws -> TypeAnnotation {
        guard let first = composition.elements.first else {
            throw unsupported("this type", composition)
        }
        let parts = try composition.elements.map { try type($0.type) }
        let names = parts.compactMap { part -> String? in
            if case .named(let name) = part { name } else { nil }
        }
        // Protocols together: `A & B`. Anything else stands for the first.
        if names.count == parts.count, names.count > 1 {
            return .named(names.joined(separator: " & "))
        }
        return try type(first.type)
    }

    private func dottedName(_ node: TypeSyntax) -> String? {
        if let identifier = node.as(IdentifierTypeSyntax.self),
            identifier.genericArgumentClause == nil
        {
            return identifier.name.text
        }
        if let member = node.as(MemberTypeSyntax.self), member.genericArgumentClause == nil,
            let base = dottedName(member.baseType)
        {
            return base + "." + member.name.text
        }
        return nil
    }
}
