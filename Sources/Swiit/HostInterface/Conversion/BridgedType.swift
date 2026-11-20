import Foundation

/// A Swift type that crosses into scripts: a host function can take and give it, and scripts can name
/// it. It says what scripts see of it (`hostType`), what type to check a parameter against
/// (`scriptType`), and how a `Value` becomes one and one becomes a `Value`.
///
/// A type that is `Sendable` conforms with no more than `extension URL: BridgedType {}`: it is held as
/// it is under its Swift name, by value if it is `Hashable` and by identity if it is a class, and its
/// registered members (`HostType.Builder`) are its members. A type that answers for members it only
/// knows at run time also conforms to ``DynamicMembers``.
///
/// The bridge generator (`swiit-bridge`), run on a module, writes `hostType` for each type the module
/// defines for scripts, and the conformance itself for one that does not declare it.
public protocol BridgedType {
    /// What scripts see of the type: its name, documentation, members and conformances. The default
    /// is a type of that Swift name with no members; a type with members says them here, and is
    /// registered with ``Interpreter/register(_:)-(HostType)``.
    static var hostType: HostType { get }
    /// The type a parameter of this type is checked against. For a type held as it is, the type
    /// `hostType` names.
    static var scriptType: ScriptType { get }
    init(_ swiitValue: Value) throws
    var value: Value { get }
}

extension BridgedType {
    public static var hostType: HostType { HostType(name: Value.hostName(of: Self.self)) }
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
