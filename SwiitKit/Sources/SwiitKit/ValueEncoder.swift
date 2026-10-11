import Foundation

/// Turns any `Encodable` Swift value into a `Value`: structs become records
/// named after their type, arrays become lists, `Date` and `FileSize` keep
/// their meaning. Most library model types already conform, so they show up
/// in Swish with no bridge code.
public struct ValueEncoder {
    public init() {}

    public func encode<T: Encodable>(_ value: T) throws -> Value {
        let slot = Slot()
        try Slot.encode(value, into: slot, codingPath: [])
        return slot.resolved()
    }
}

extension Value {
    /// A best-effort `Value` for anything, from its `Mirror`: for types that
    /// aren't `Encodable`, enough to display them and pick fields out.
    public init(reflecting subject: Any) {
        self = Value.reflect(subject, depth: 0)
    }

    private static func reflect(_ subject: Any, depth: Int) -> Value {
        switch subject {
        case let value as Value: return value
        case let bool as Bool: return .bool(bool)
        case let int as Int: return .int(int)
        case let double as Double: return .double(double)
        case let string as String: return .string(string)
        case let date as Date: return .date(date)
        case let size as FileSize: return .fileSize(size)
        case let url as URL: return .string(url.isFileURL ? url.path : url.absoluteString)
        case let integer as any BinaryInteger: return Int(exactly: integer).map(Value.int) ?? .double(Double(integer))
        case let float as any BinaryFloatingPoint: return .double(Double(float))
        default: break
        }

        // Stop somewhere, since objects can refer to each other in cycles.
        guard depth < 8 else { return .string(String(describing: subject)) }
        let mirror = Mirror(reflecting: subject)
        switch mirror.displayStyle {
        case .optional:
            return mirror.children.first.map { reflect($0.value, depth: depth) } ?? .nothing
        case .collection, .set:
            return .list(mirror.children.map { reflect($0.value, depth: depth + 1) })
        case .dictionary:
            var record = Record()
            for child in mirror.children {
                let pair = Array(Mirror(reflecting: child.value).children)
                guard pair.count == 2 else { continue }
                record[String(describing: pair[0].value)] = reflect(pair[1].value, depth: depth + 1)
            }
            return .record(record)
        case .struct, .class, .tuple:
            var record = Record(typeName: mirror.displayStyle == .tuple ? nil : String(describing: type(of: subject)))
            for (index, child) in mirror.children.enumerated() {
                // Unlabeled tuple elements come through as ".0", ".1", ….
                let label = child.label.map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }
                record[label ?? "\(index)"] = reflect(child.value, depth: depth + 1)
            }
            return .record(record)
        default:
            return .string(String(describing: subject))
        }
    }
}

// MARK: - Encoder

/// Where one value's encoding ends up. Containers hand out slots for their
/// children, and the tree is resolved into a `Value` at the end.
private final class Slot {
    var value: Value = .nothing
    var record: RecordBuilder?
    var list: [Slot]?

    func resolved() -> Value {
        if let record {
            var result = Record(typeName: record.typeName)
            for key in record.keys { result[key] = record.slots[key]!.resolved() }
            return .record(result)
        }
        if let list { return .list(list.map { $0.resolved() }) }
        return value
    }

    static func encode<T: Encodable>(_ value: T, into slot: Slot, codingPath: [any CodingKey]) throws {
        switch value {
        case let date as Date: slot.value = .date(date)
        case let size as FileSize: slot.value = .fileSize(size)
        case let url as URL: slot.value = .string(url.isFileURL ? url.path : url.absoluteString)
        case let decimal as Decimal: slot.value = .double(NSDecimalNumber(decimal: decimal).doubleValue)
        default:
            let typeName = String(describing: T.self)
            try value.encode(to: SlotEncoder(slot: slot, codingPath: codingPath, typeName: typeName))
        }
    }

    static func integer<T: BinaryInteger>(_ value: T, _ codingPath: [any CodingKey]) throws -> Value {
        guard let int = Int(exactly: value) else {
            throw EncodingError.invalidValue(value, .init(codingPath: codingPath, debugDescription: "\(value) doesn't fit in an Int"))
        }
        return .int(int)
    }
}

private final class RecordBuilder {
    let typeName: String?
    var keys: [String] = []
    var slots: [String: Slot] = [:]

    init(typeName: String?) {
        self.typeName = typeName
    }

    func slot(for key: String) -> Slot {
        if let slot = slots[key] { return slot }
        let slot = Slot()
        keys.append(key)
        slots[key] = slot
        return slot
    }
}

private struct SlotEncoder: Encoder {
    let slot: Slot
    let codingPath: [any CodingKey]
    let typeName: String?
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        if slot.record == nil { slot.record = RecordBuilder(typeName: typeName) }
        return KeyedEncodingContainer(KeyedContainer(record: slot.record!, codingPath: codingPath))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        if slot.list == nil { slot.list = [] }
        return UnkeyedContainer(owner: slot, codingPath: codingPath)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer {
        SingleContainer(slot: slot, codingPath: codingPath)
    }
}

private struct KeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let record: RecordBuilder
    let codingPath: [any CodingKey]

    private func set(_ value: Value, _ key: Key) { record.slot(for: key.stringValue).value = value }

    mutating func encodeNil(forKey key: Key) throws { set(.nothing, key) }
    mutating func encode(_ value: Bool, forKey key: Key) throws { set(.bool(value), key) }
    mutating func encode(_ value: String, forKey key: Key) throws { set(.string(value), key) }
    mutating func encode(_ value: Double, forKey key: Key) throws { set(.double(value), key) }
    mutating func encode(_ value: Float, forKey key: Key) throws { set(.double(Double(value)), key) }
    mutating func encode(_ value: Int, forKey key: Key) throws { set(.int(value), key) }
    mutating func encode(_ value: Int8, forKey key: Key) throws { set(.int(Int(value)), key) }
    mutating func encode(_ value: Int16, forKey key: Key) throws { set(.int(Int(value)), key) }
    mutating func encode(_ value: Int32, forKey key: Key) throws { set(.int(Int(value)), key) }
    mutating func encode(_ value: Int64, forKey key: Key) throws { set(.int(Int(value)), key) }
    mutating func encode(_ value: UInt, forKey key: Key) throws { set(try Slot.integer(value, codingPath + [key]), key) }
    mutating func encode(_ value: UInt8, forKey key: Key) throws { set(.int(Int(value)), key) }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { set(.int(Int(value)), key) }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { set(.int(Int(value)), key) }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { set(try Slot.integer(value, codingPath + [key]), key) }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        try Slot.encode(value, into: record.slot(for: key.stringValue), codingPath: codingPath + [key])
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type, forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        SlotEncoder(slot: record.slot(for: key.stringValue), codingPath: codingPath + [key], typeName: nil)
            .container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        SlotEncoder(slot: record.slot(for: key.stringValue), codingPath: codingPath + [key], typeName: nil)
            .unkeyedContainer()
    }

    mutating func superEncoder() -> any Encoder {
        SlotEncoder(slot: record.slot(for: "super"), codingPath: codingPath, typeName: nil)
    }

    mutating func superEncoder(forKey key: Key) -> any Encoder {
        SlotEncoder(slot: record.slot(for: key.stringValue), codingPath: codingPath + [key], typeName: nil)
    }
}

private struct IndexKey: CodingKey {
    let intValue: Int?
    var stringValue: String { "\(intValue!)" }
    init(_ index: Int) { intValue = index }
    init?(stringValue: String) { nil }
    init?(intValue: Int) { self.intValue = intValue }
}

private struct UnkeyedContainer: UnkeyedEncodingContainer {
    let owner: Slot
    let codingPath: [any CodingKey]
    var count: Int { owner.list!.count }

    private func next() -> Slot {
        let slot = Slot()
        owner.list!.append(slot)
        return slot
    }

    mutating func encodeNil() throws { next().value = .nothing }
    mutating func encode(_ value: Bool) throws { next().value = .bool(value) }
    mutating func encode(_ value: String) throws { next().value = .string(value) }
    mutating func encode(_ value: Double) throws { next().value = .double(value) }
    mutating func encode(_ value: Float) throws { next().value = .double(Double(value)) }
    mutating func encode(_ value: Int) throws { next().value = .int(value) }
    mutating func encode(_ value: Int8) throws { next().value = .int(Int(value)) }
    mutating func encode(_ value: Int16) throws { next().value = .int(Int(value)) }
    mutating func encode(_ value: Int32) throws { next().value = .int(Int(value)) }
    mutating func encode(_ value: Int64) throws { next().value = .int(Int(value)) }
    mutating func encode(_ value: UInt) throws { next().value = try Slot.integer(value, codingPath) }
    mutating func encode(_ value: UInt8) throws { next().value = .int(Int(value)) }
    mutating func encode(_ value: UInt16) throws { next().value = .int(Int(value)) }
    mutating func encode(_ value: UInt32) throws { next().value = .int(Int(value)) }
    mutating func encode(_ value: UInt64) throws { next().value = try Slot.integer(value, codingPath) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        try Slot.encode(value, into: next(), codingPath: codingPath + [IndexKey(count)])
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        SlotEncoder(slot: next(), codingPath: codingPath, typeName: nil).container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
        SlotEncoder(slot: next(), codingPath: codingPath, typeName: nil).unkeyedContainer()
    }

    mutating func superEncoder() -> any Encoder {
        SlotEncoder(slot: next(), codingPath: codingPath, typeName: nil)
    }
}

private struct SingleContainer: SingleValueEncodingContainer {
    let slot: Slot
    let codingPath: [any CodingKey]

    mutating func encodeNil() throws { slot.value = .nothing }
    mutating func encode(_ value: Bool) throws { slot.value = .bool(value) }
    mutating func encode(_ value: String) throws { slot.value = .string(value) }
    mutating func encode(_ value: Double) throws { slot.value = .double(value) }
    mutating func encode(_ value: Float) throws { slot.value = .double(Double(value)) }
    mutating func encode(_ value: Int) throws { slot.value = .int(value) }
    mutating func encode(_ value: Int8) throws { slot.value = .int(Int(value)) }
    mutating func encode(_ value: Int16) throws { slot.value = .int(Int(value)) }
    mutating func encode(_ value: Int32) throws { slot.value = .int(Int(value)) }
    mutating func encode(_ value: Int64) throws { slot.value = .int(Int(value)) }
    mutating func encode(_ value: UInt) throws { slot.value = try Slot.integer(value, codingPath) }
    mutating func encode(_ value: UInt8) throws { slot.value = .int(Int(value)) }
    mutating func encode(_ value: UInt16) throws { slot.value = .int(Int(value)) }
    mutating func encode(_ value: UInt32) throws { slot.value = .int(Int(value)) }
    mutating func encode(_ value: UInt64) throws { slot.value = try Slot.integer(value, codingPath) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        try Slot.encode(value, into: slot, codingPath: codingPath)
    }
}
