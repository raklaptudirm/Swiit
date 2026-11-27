import Foundation

// Evaluating member access and subscripts on values.

extension Interpreter {
    /// Record fields first, then the few members values have.
    func member(_ name: String, of value: Value) throws -> Value {
        if let found = try typeMember(name, of: value) { return found }
        if case .object(let object) = value.storage,
            name != "description" && name != "debugDescription"
        {
            return try objectMember(name, of: object, value)
        }
        if let found = try textMember(name, of: value) { return found }
        if let record = value.record { return try recordMember(name, of: record, value) }
        return try swiftMember(name, of: value)
    }

    /// What the type of `value` declares, or an extension of it adds: an enum's raw value and members,
    /// an instance's and a class's members, the static members of a type, and a case of an enum. A
    /// struct's own members come before what extensions add, so a record's are looked for later.
    private func typeMember(_ name: String, of value: Value) throws -> Value? {
        if case .enumValue(let enumValue) = value.storage, name == "rawValue" {
            guard let raw = enumValue.rawValue else {
                throw RuntimeError("\(enumValue.type.name) has no raw values")
            }
            return raw
        }
        if case .enumValue(let enumValue) = value.storage,
            let found = try enumMember(name, of: enumValue)
        {
            return found
        }
        if case .object(let instance as ClassInstance) = value.storage,
            let found = try classMember(name, of: instance)
        {
            return found
        }
        if case .object(let type as ClassType) = value.storage,
            let found = try classStaticMember(name, of: type)
        {
            return found
        }
        if value.record == nil, let found = try extensionMember(name, of: value) { return found }
        if let typeName = declaredTypeName(of: value),
            let found = try extensionStaticMember(name, ofTypeNamed: typeName)
        {
            return found
        }
        if case .object(let type as Value.EnumCase.Enumeration) = value.storage {
            if let found = try enumStaticMember(name, of: type) { return found }
            if type.case(named: name) != nil, type.member(name) == nil {
                return try makeCase(type, name, nil)  // Says what values it needs.
            }
        }
        if case .object(let type as StructType) = value.storage,
            let found = try staticMember(name, of: type)
        {
            return found
        }
        return nil
    }

    /// A member of a live value with members of its own (a Swift value, a background job): Swift's
    /// property or method of that name, or the object's own.
    private func objectMember(
        _ name: String,
        of object: any LanguageObject,
        _ value: Value
    ) throws -> Value {
        if let property = try bridgedProperty(name, of: value) { return property }
        if let method = bridgedMethods(name, of: value) { return method }
        guard let member = object.member(name) else {
            throw RuntimeError("\(object.typeName) has no member '\(name)'")
        }
        return member
    }

    /// The text every value has. `description` and `debugDescription` are its textual form, as a
    /// CustomStringConvertible's is in Swift: what interpolation shows. `localizedDescription` is what
    /// an Error says of itself, unless its type says otherwise: its value, as Swift's describes an
    /// error it has no message for. A record's own field of the name comes first.
    private func textMember(_ name: String, of value: Value) throws -> Value? {
        if name == "description" || name == "debugDescription" {
            if let record = value.record, let field = record[name] { return field }
            return .string(name == "description" ? value.description : value.debugDescription)
        }
        if name == "localizedDescription", isError(value) {
            if let record = value.record, let field = record[name] { return field }
            if let record = value.record, let type = structType(of: record),
                let found = try structMember(name, of: record, type)
            {
                return found
            }
            return .string(value.description)
        }
        return nil
    }

    /// A member of a struct's value or a tuple: `pair.1` by position, labeled or not; a field; what the
    /// struct or an extension declares; and what every record has (`count`, `isEmpty`, `keys`,
    /// `values`).
    private func recordMember(
        _ name: String,
        of record: Value.Record,
        _ value: Value
    ) throws -> Value {
        if record.typeName == nil, record[name] == nil, let position = Int(name), position >= 0,
            position < record.count
        {
            return Array(record)[position].value
        }
        if record[name] == nil, let type = structType(of: record),
            let found = try structMember(name, of: record, type)
        {
            return found
        }
        if let found = try extensionMember(name, of: value) { return found }

        if let field = record[name] { return field }
        switch name {
        case "count": return .int(record.count)
        case "isEmpty": return .bool(record.isEmpty)
        case "keys": return .list(record.keys.map(Value.string))
        case "values": return .list(record.map(\.value))
        default: throw RuntimeError("\(record.typeName ?? "Tuple") has no field '\(name)'")
        }
    }

    /// Swift's own properties and methods of a value of a built-in kind, as a key path like `\.count`
    /// reads them.
    private func swiftMember(_ name: String, of value: Value) throws -> Value {
        if let property = try bridgedProperty(name, of: value) { return property }
        if let method = bridgedMethods(name, of: value) { return method }
        throw RuntimeError("\(value.typeName) has no member '\(name)'")
    }

    /// `value[key]`: what a subscript of a struct or a class gives, or the element of a list, a
    /// dictionary or a string.
    func readIndex(_ value: Value, key: Value) throws -> Value {
        if let record = value.record, let type = structType(of: record),
            !type.members.subscriptGetters.isEmpty
        {
            return try readSubscript(record, type, [Argument(value: .literal(key))])
        }
        if case .object(let instance as ClassInstance) = value.storage {
            return try readSubscript(instance, [Argument(value: .literal(key))])
        }
        return try element(of: value, at: key)
    }

    func element(of base: Value, at index: Value) throws -> Value {
        // A subscript a bridged type declares, where the checker did not know the type.
        switch base.storage {
        case .list, .dictionary: break
        default:
            if base.record == nil, let subscripted = bridgedMethods("subscript", of: base) {
                return try call(subscripted, with: [index])
            }
        }
        if case .dictionary(let dictionary) = base.storage {
            return dictionary[index] ?? .nothing
        }
        if let record = base.record, case .string(let key) = index.storage {
            return record[key] ?? .nothing
        }
        // A Swift sequence Swiit holds is indexed by position (a host type's text, by line);
        // subscripts aren't bridged yet.
        if case .object = base.storage, let items = Interpreter.items(of: base) {
            return try element(of: .list(Array(items)), at: index)
        }
        guard case .list(let elements) = base.storage else {
            throw RuntimeError("\(base.typeName) can't be indexed")
        }
        // `xs[1...3]`: a slice, as Swift's ArraySlice.
        if case .object(let box as SwiftValue) = index.storage {
            var bounds: Range<Int>?
            if let range = box.value as? ClosedRange<Value>,
                case .int(let low) = range.lowerBound.storage,
                case .int(let high) = range.upperBound.storage, high < Int.max
            {
                bounds = low..<(high + 1)
            } else if let range = box.value as? Range<Value>,
                case .int(let low) = range.lowerBound.storage,
                case .int(let high) = range.upperBound.storage
            {
                bounds = low..<high
            }
            if let bounds {
                guard bounds.lowerBound >= 0, bounds.upperBound <= elements.count else {
                    throw RuntimeError(
                        "range \(bounds.lowerBound)..<\(bounds.upperBound) is out of range for a list of \(elements.count)"
                    )
                }
                return SwiftValue.make(ArraySlice(elements[bounds]), as: "ArraySlice")
            }
        }
        guard case .int(let i) = index.storage else {
            throw RuntimeError("a list index must be an Int, not \(index.typeName)")
        }
        guard elements.indices.contains(i) else {
            throw RuntimeError("index \(i) is out of range for a list of \(elements.count)")
        }
        return elements[i]
    }
}
