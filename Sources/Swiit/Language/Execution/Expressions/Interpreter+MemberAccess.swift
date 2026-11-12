import Foundation

// Evaluating member access and subscripts on values.

extension Interpreter {
    // swiftlint:disable cyclomatic_complexity - one branch for each case; splitting it is item 17 of Docs/agenda.md
    /// Record fields first, then the few members values have.
    func member(_ name: String, of value: Value) throws -> Value {
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
        // A struct's own members come before what extensions add.
        if value.record != nil {
        } else if let found = try extensionMember(name, of: value) {
            return found
        }
        if let typeName = declaredTypeName(of: value),
            let found = try extensionStaticMember(name, ofTypeNamed: typeName)
        {
            return found
        }
        if case .object(let type as Value.EnumCase.Enumeration) = value.storage,
            let found = try enumStaticMember(name, of: type)
        {
            return found
        }
        if case .object(let type as Value.EnumCase.Enumeration) = value.storage,
            type.case(named: name) != nil,
            type.member(name) == nil
        {
            return try makeCase(type, name, nil)  // Says what values it needs.
        }
        if case .object(let type as StructType) = value.storage,
            let found = try staticMember(name, of: type)
        {
            return found
        }
        if case .object(let object) = value.storage,
            name != "description" && name != "debugDescription"
        {
            if let property = try bridgedProperty(name, of: value) { return property }
            if let method = bridgedMethods(name, of: value) { return method }
            guard let member = object.member(name) else {
                throw RuntimeError("\(object.typeName) has no member '\(name)'")
            }
            return member
        }
        // Every value has its textual form, as a CustomStringConvertible
        // does in Swift: what interpolation shows. A record's own field of
        // that name comes first.
        if name == "description" || name == "debugDescription" {
            if let record = value.record, let field = record[name] { return field }
            return .string(name == "description" ? value.description : value.debugDescription)
        }
        // What every Error says of itself, unless its type says otherwise: its
        // value, as Swift's describes an error it has no message for.
        if name == "localizedDescription", isError(value) {
            if let record = value.record, let field = record[name] { return field }
            if let record = value.record, let type = structType(of: record),
                let found = try structMember(name, of: record, type)
            {
                return found
            }
            return .string(value.description)
        }
        // `pair.1`: a tuple's element by position, labeled or not.
        if let record = value.record, record.typeName == nil, record[name] == nil,
            let position = Int(name), position >= 0, position < record.count
        {
            return Array(record)[position].value
        }
        if let record = value.record, record[name] == nil, let type = structType(of: record),
            let found = try structMember(name, of: record, type)
        {
            return found
        }
        if value.record != nil, let found = try extensionMember(name, of: value) { return found }
        // A record's fields, then (below) Swift's own members of the other kinds.
        switch (value.storage, name) {
        case _ where value.record?[name] != nil: return value.record![name]!
        case (_, "count") where value.record != nil: return .int(value.record!.count)
        case (_, "isEmpty") where value.record != nil: return .bool(value.record!.isEmpty)
        case (_, "keys") where value.record != nil:
            return .list(value.record!.keys.map(Value.string))
        case (_, "values") where value.record != nil: return .list(value.record!.map(\.value))
        case _ where value.record != nil:
            throw RuntimeError("\(value.record!.typeName ?? "Tuple") has no field '\(name)'")
        default:
            // Swift's own properties, as a key path like `\.count` reads them.
            if let property = try bridgedProperty(name, of: value) { return property }
            if let method = bridgedMethods(name, of: value) { return method }
            throw RuntimeError("\(value.typeName) has no member '\(name)'")
        }
    }
    // swiftlint:enable cyclomatic_complexity

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
