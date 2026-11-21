import Foundation

/// A Swift type that crosses into scripts: a host function can take and give it, and scripts can name
/// it. It says how a `Value` becomes one and one becomes a `Value`, what scripts see of the type
/// (`typeImplementation`) and what type to check a parameter against (`typeExpression`).
///
/// A type that is `Sendable` conforms with no more than `extension URL: BridgedValue {}`: it is held as
/// it is under its Swift name, by value if it is `Hashable` and by identity if it is a class, and its
/// registered members (`BridgedType`) are its members.
///
/// The bridge generator (`swiit-bridge`), run on a module, writes `typeImplementation` for each type the module
/// defines for scripts, and the conformance itself for one that does not declare it.
public protocol BridgedValue {
    /// The Swift value a script value stands for, or an error saying what was expected instead.
    init(_ swiitValue: Value) throws
    /// The script value this Swift value is.
    var value: Value { get }

    /// What scripts see of the type: its name, documentation, members and conformances. The default
    /// is a type of that Swift name with no members; a type with members says them here, and is
    /// registered with ``Interpreter/register(_:)-(TypeImplementation)``.
    static var typeImplementation: TypeImplementation { get }
    /// The type a parameter of this type is checked against. For a type held as it is, the type
    /// `typeImplementation` names.
    static var typeExpression: TypeExpression { get }
}

extension BridgedValue {
    public static var typeImplementation: TypeImplementation {
        TypeImplementation(name: Value.hostName(of: Self.self))
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
