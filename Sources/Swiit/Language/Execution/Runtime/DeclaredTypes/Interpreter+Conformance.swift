import Foundation

// Whether a value is of a type, and the value as that type: an instance of a class or of a subclass,
// a value of a type that conforms to a protocol, a boxed Swift value, a collection, an optional, a
// tuple, a type, or what a type parameter is bound to.

extension Interpreter {
    /// An expression whose type is known from context: a `.case` literal
    /// becomes a case of the expected enum.
    func evaluate(_ expr: Expr, expecting type: TypeExpression?) throws -> Value {
        if case .caseLiteral(let name, let arguments) = expr, let enumType = enumType(for: type) {
            return try makeCase(enumType, name, arguments)
        }
        return try evaluate(expr)
    }

    /// `value` as `type`, knowing the enums in scope; nil if it doesn't fit.
    func conform(_ value: Value, to type: TypeExpression) -> Value? {
        // A value already of a plain type, which is nearly every argument and result.
        switch (type, value.storage) {
        case (.int, .int), (.double, .double), (.string, .string), (.bool, .bool), (.any, _):
            return value
        default: break
        }
        if type.sequenceElement != nil {
            // Any sequence; the glue takes its items.
            return value
        }
        if type.isNominal, !type.isPrimitive, type.plainName != nil || type.genericParts != nil {
            return conformNamed(value, to: type)
        }
        return conformStructured(value, to: type)
    }

    /// A value of a named type: a class, a protocol, a struct, an enum, a Swift value.
    private func conformNamed(_ value: Value, to type: TypeExpression) -> Value? {
        if let (name, _) = type.genericParts {
            // A Swift value, boxed, is of its Swift type.
            if case .object(let box as SwiftValue) = value.storage, box.typeName == name {
                return value
            }
            // A generic enum of the program's: its arguments say what its cases hold, and it is its
            // name.
            if enumType(named: name) != nil { return conform(value, to: .named(name)) }
            // A generic protocol of the program's (`Job<Int>`): a value whose type conforms; what it
            // holds is the checker's to say, since a value does not carry it.
            if protocolType(named: name) != nil { return conform(value, to: .named(name)) }
            return nil
        }
        guard let name = type.plainName else {
            preconditionFailure("this was sent to the wrong group")
        }
        if name.contains(" & ") {
            // `A & B`: a value that is each.
            var held = value
            for part in name.components(separatedBy: " & ") {
                guard let conforming = conform(held, to: .named(part)) else { return nil }
                held = conforming
            }
            return held
        }
        // A class of the program's: an instance of it or of a subclass.
        if let type = classType(named: name) {
            guard case .object(let instance as ClassInstance) = value.storage,
                instance.type.isSubclass(of: type)
            else {
                return nil
            }
            return value
        }
        // A protocol of the program's: any value whose type conforms.
        if protocolType(named: name) != nil {
            return self.value(value, conformsTo: name) ? value : nil
        }
        // A Swift value, boxed, is of its Swift type.
        if case .object(let box as SwiftValue) = value.storage, box.typeName == name {
            return value
        }
        // A Character is held as the one-letter String it is.
        if name == "Character", case .string(let text) = value.storage, text.count == 1 {
            return value
        }
        if let record = value.record, record.typeName == name,
            structType(named: name) != nil
        {
            return value
        }
        // An Error is any value whose type conforms to it.
        if name == "Error", isError(value) { return value }
        guard case .enumValue(let enumValue) = value.storage,
            let expected = enumType(named: name),
            enumValue.type === expected
        else { return nil }
        return value
    }

    /// A value of a type made of others: a collection, a tuple, an optional, a type parameter.
    private func conformStructured(_ value: Value, to type: TypeExpression) -> Value? {
        if case .metatype(let metatype) = type {
            // A type, of the kind the type parameter or class says (a subclass's type is its
            // superclass's too).
            let wrapped = metatype.instance
            guard let held = representedType(ofTypeValue: value) else { return nil }
            if wrapped == .any || wrapped == .unknown { return value }
            if case .parameter = wrapped { return value }
            if let name = wrapped.plainName {
                if case .object(let object as ClassType) = value.storage,
                    let above = classType(named: name)
                {
                    return object.isSubclass(of: above) ? value : nil
                }
                if protocolType(named: name) != nil || name == "Error" {
                    return typeValue(value, conformsTo: name) ? value : nil
                }
            }
            return held == wrapped ? value : nil
        }
        if case .parameter(let parameter) = type {
            // A type parameter is what the call bound it to, if the body names it; otherwise any
            // type.
            guard hasBoundTypeArguments,
                let bound = lookup(Interpreter.typeArgumentPrefix + parameter.name)?.value,
                let represented = representedType(ofTypeValue: bound)
            else { return value }
            return conform(value, to: represented)
        }
        if let wrapped = type.optionalWrapped {
            return value == .nothing ? value : conform(value, to: wrapped)
        }
        if let element = type.arrayElement {
            guard case .list(let items) = value.storage else { return value.conforming(to: type) }
            var converted: [Value] = []
            for item in items {
                guard let conforming = conform(item, to: element) else { return nil }
                converted.append(conforming)
            }
            return .list(converted)
        }
        if let (keyType, valueType) = type.dictionaryTypes {
            guard case .dictionary(let dictionary) = value.storage else {
                return value.conforming(to: type)
            }
            var made: [Value: Value] = [:]
            for (key, entry) in dictionary {
                guard let conformingKey = conform(key, to: keyType),
                    let conformingValue = conform(entry, to: valueType)
                else { return nil }
                made[conformingKey] = conformingValue
            }
            return .dictionary(made)
        }
        if case .tuple(let tuple) = type, !tuple.elements.isEmpty {
            let elements = tuple.elements
            // Each element as its own type, which may be a protocol of the program's.
            guard let record = value.record, record.typeName == nil,
                record.count == elements.count
            else {
                return value.conforming(to: type)
            }
            var made = Value.Record()
            for (element, field) in zip(elements, record) {
                guard let conforming = conform(field.value, to: element.type) else { return nil }
                made[element.label ?? field.key] = conforming
            }
            return Value(record: made)
        }
        return value.conforming(to: type)
    }
}
