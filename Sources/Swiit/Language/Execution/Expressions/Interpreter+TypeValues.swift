import Foundation

// Generic type values: specialized types and their annotations.

extension Interpreter {
    static let typeArgumentPrefix = InternalName.typeArgumentPrefix

    /// A generic function with its type parameters bound to the types of one call, as values the
    /// body can name.
    func specialized(_ function: Value, _ types: [TypeArgument]) -> Value {
        var bindings: [String: Binding] = [:]
        for type in types {
            if let object = typeValue(of: type.type) {
                hasBoundTypeArguments = true
                bindings[type.name] = Binding(value: object, mutable: false)
                // Kept under a name no program writes, for a test against it (`x as? T`), which a
                // global type of the same name mustn't answer.
                bindings[Interpreter.typeArgumentPrefix + type.name] = Binding(
                    value: object,
                    mutable: false
                )
            }
        }
        guard !bindings.isEmpty, case .function(let callable) = function.storage else {
            return function
        }
        let scope = Scope(bindings)
        if let set = callable as? OverloadSet {
            return .function(
                OverloadSet(
                    name: set.name,
                    candidates: set.candidates.map {
                        $0.typeParameters.isEmpty ? $0 : $0.capturing(scope)
                    }
                )
            )
        }
        if let single = callable as? Function, !single.typeParameters.isEmpty {
            return .function(single.capturing(scope))
        }
        return function
    }

    /// The value that stands for a type (`Int.self`), if one does: a type parameter's is whatever
    /// it is bound to here.
    func typeValue(of type: TypeExpression) -> Value? {
        let name: String
        if let representation = ImplementedType.Representation(type) {
            name = representation.name!
        } else if case .named(let named) = type {
            name = named.reference.name
        } else if case .parameter(let parameter) = type {
            return lookup(parameter.name)?.value
        } else {
            return nil
        }
        return lookup(name)?.value
    }

    /// The type a type value stands for, to test a value against.
    func representedType(ofTypeValue value: Value) -> TypeExpression? {
        guard case .object(let object) = value.storage else { return nil }
        let name: String
        switch object {
        case let type as ClassType: name = type.name
        case let type as StructType: name = type.name
        case let type as Value.EnumCase.Enumeration: name = type.name
        case let type as ProtocolType: name = type.name
        case let type as NativeTypeName: name = type.name
        default: return nil
        }
        return TypeExpression.spelled(name) ?? .named(name)
    }
}
