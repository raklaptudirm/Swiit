import Foundation

// A value from any Encodable Swift value.

extension Value {
    /// Any `Encodable` as a value: a struct, a list, a string. A struct is of a host type named for
    /// its Swift type, or of `type` if one is given.
    public init(encoding value: some Encodable, as type: Symbol.ID? = nil) throws {
        self = try ValueEncoder().encode(value)
        if let type, var record = record {
            record.typeID = type
            self = Value(record: record)
        }
    }
}
