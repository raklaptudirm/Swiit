import Foundation

/// A Swift type that can be a parameter: the host hands it a `Value`, and
/// it says what type the host should check for.
///
/// It is also how a type is held as it is: a type that is `Sendable` and conforms with no more than
/// `extension URL: BridgedType {}` is held under its Swift name, by value if it is `Hashable`
/// and by identity if it is a class, and its registered members are its members (`HostType.Builder`). A
/// type that answers for members it only knows at run time, like a parsed object's keys, says them.
public protocol BridgedType {
    static var scriptType: ScriptType { get }
    init(_ swiitValue: Value) throws
    var value: Value { get }
    /// The names of the members it answers for at run time, in order, or nil, the default, if all
    /// its members are registered. A type with names is laid out as a record is, in a table and in
    /// JSON.
    var memberNames: [String]? { get }
    /// A member answered at run time, after the registered ones; nil if there is none.
    func member(_ name: String) -> Value?
}

extension BridgedType {
    public var memberNames: [String]? { nil }
    public func member(_ name: String) -> Value? { nil }
}

/// A type that names enums in its `scriptType`, which scripts learn by name: containers hold their
/// elements'. An SPI refinement, because a requirement only the module can see cannot be satisfied
/// by a conformance outside it.
protocol ValueEnums { static var enumTypes: [Value.EnumCase.Enumeration] { get } }

extension BridgedType {
    /// The enums `scriptType` names.
    static var swiitEnums: [Value.EnumCase.Enumeration] {
        if let carrier = self as? any ValueEnums.Type { return carrier.enumTypes }
        if let enumeration = self as? any CaseIterable.Type {
            return [Value.EnumCase.Enumeration.of(enumeration)]
        }
        return []
    }
}
