import Foundation

/// A Swift type a script can hold: host functions can take and return it, and scripts can name it. The
/// conformance says how a `Value` converts to the type and back (`init(_:)` and `value`), what scripts
/// see of the type (`implementedType`), and which type a parameter of it is checked against
/// (`typeExpression`).
///
/// A `Sendable` type conforms with `extension URL: BridgedValue {}`. It is then held as it is under its
/// Swift name, by value if it is `Hashable` and by identity if it is a class, and its members are the
/// ones registered with `BridgedType`.
///
/// The bridge generator (`swiit-bridge`) writes `implementedType` for each type a module defines for
/// scripts, and the conformance for each one that does not declare it.
public protocol BridgedValue {
    /// The Swift value a script value stands for, or an error saying what was expected instead.
    init(_ swiitValue: Value) throws
    /// The script value this Swift value is.
    var value: Value { get }

    /// What scripts see of the type: its name, documentation, members and conformances. The default
    /// is a type of that Swift name with no members; a type with members says them here, and is
    /// registered with ``Interpreter/register(_:)-(ImplementedType)``.
    static var implementedType: ImplementedType { get }
    /// The type a parameter of this type is checked against. For a type held as it is, the type
    /// `implementedType` names.
    static var typeExpression: TypeExpression { get }
}

extension BridgedValue {
    public static var implementedType: ImplementedType {
        ImplementedType(name: Value.hostName(of: Self.self))
    }
}

/// A type that names enums in its `typeExpression`, which scripts learn by name: containers hold their
/// elements'. An SPI refinement, because a requirement only the module can see cannot be satisfied
/// by a conformance outside it.
protocol ValueEnums { static var enumTypes: [Value.EnumCase.Enumeration] { get } }

extension BridgedValue {
    /// The enums `typeExpression` names.
    static var swiitEnums: [Value.EnumCase.Enumeration] {
        if let carrier = self as? any ValueEnums.Type { return carrier.enumTypes }
        if let enumeration = self as? any CaseIterable.Type {
            return [Value.EnumCase.Enumeration.of(enumeration)]
        }
        return []
    }
}
