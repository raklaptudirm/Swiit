import Foundation
import SwiftSyntax
import Synchronization

// A reference to a type: the declaration it is, not the name it goes by.

/// Names a type, or stands where one would be: what `register` gives back, what
/// `TypeRef(named:in:)` finds, what `Value.typeRef` has, and what `ScriptType.named` and
/// `Value.isInstance(of:)` take. A host gets one from the interpreter (`register`,
/// `TypeRef(named:in:)`, `Symbol.id`, a value's `typeRef`), and mints one only for a Swift type it
/// registers (`init(hostType:)`).
///
/// A reference is one of three kinds:
/// - **Declared**: a type a script declares. It names one declaration, made once in this
///   process. Declaring `struct Point` again makes a new type with a new reference, and the old one
///   keeps naming the old one. A host cannot make one; it comes from the interpreter, so a
///   misspelling cannot name a declaration. A reference from another interpreter is just one this
///   interpreter never made, and names nothing.
/// - **Host**: a Swift type the host or the core provides (`Int`, `Array`, a registered
///   `FileSize`, an encoded Swift value), by the name `String(describing:)` gives the Swift
///   type, which has no module in it. Host types are process-wide and one per name, as the
///   registry they live in is: two Swift types of one name in different modules collide, and an
///   encoded value carries only the name. A reference of this kind may name nothing (a type not
///   registered, or an encoded value's), and `TypeRef.symbol(in:)` then gives nil.
/// - **Parameter**: a generic parameter (`Element`), by name, with nothing declared under it.
///
/// References are equal when they are the same kind and the same declaration, or the same name. They
/// do not outlive the process.
public struct TypeRef: Sendable, Hashable, CustomStringConvertible {
    enum Kind: Sendable, Hashable { case declared(UInt64), host, parameter }

    let kind: Kind
    /// The type's name as a script writes it: for display, not identity. Two IDs can share a
    /// name and be different types (a type declared again), and a host type's reference is its name alone.
    public let name: String

    private init(_ kind: Kind, _ name: String) {
        self.kind = kind
        self.name = name
    }

    /// Whether this names a generic parameter (`Element`): a placeholder for a type, which
    /// nothing is declared under.
    public var isGenericParameter: Bool {
        if case .parameter = kind { true } else { false }
    }

    static func host(_ name: String) -> TypeRef { TypeRef(.host, name) }
    static func parameter(_ name: String) -> TypeRef { TypeRef(.parameter, name) }

    /// A new declaration's reference, from a counter shared by the process.
    static func declare(_ name: String) -> TypeRef {
        TypeRef(
            .declared(
                counter.withLock {
                    $0 += 1; return $0
                }
            ),
            name
        )
    }
    private static let counter = Mutex<UInt64>(0)

    /// The reference to a Swift type the host is about to register, for the places that need it
    /// before there is an interpreter to ask or before the type is registered: a `scriptType`
    /// that is a static property, a type's own members that name it. It equals the reference
    /// `register` gives for the type of that name, and the same name's in another interpreter,
    /// and can never equal a script's type. Everywhere else, pass around what `register` gave
    /// back, or ask `TypeRef(named:in:)`.
    public init(hostType name: String) { self.init(.host, name) }

    public var description: String { name }

    public static func == (lhs: TypeRef, rhs: TypeRef) -> Bool {
        switch (lhs.kind, rhs.kind) {
        case (.declared(let a), .declared(let b)): a == b
        case (.host, .host), (.parameter, .parameter): lhs.name == rhs.name
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch kind {
        case .declared(let token): hasher.combine(token)
        case .host: hasher.combine(0); hasher.combine(name)
        case .parameter: hasher.combine(1); hasher.combine(name)
        }
    }

    /// Swift's own, which scripts have and hosts match on.
    public static let any = TypeRef.host("Any")
    public static let bool = TypeRef.host("Bool")
    public static let int = TypeRef.host("Int")
    public static let double = TypeRef.host("Double")
    public static let string = TypeRef.host("String")
    public static let array = TypeRef.host("Array")
    public static let arraySlice = TypeRef.host("ArraySlice")
    public static let set = TypeRef.host("Set")
    public static let dictionary = TypeRef.host("Dictionary")
    public static let optional = TypeRef.host("Optional")
    public static let function = TypeRef.host("Function")
    public static let keyPath = TypeRef.host("KeyPath")
    public static let sequence = TypeRef.host("Sequence")
    public static let rawRepresentable = TypeRef.host("RawRepresentable")

    /// Lets a pattern say `case .named("Array", …)` inside the module, which a literal
    /// conformance would offer to every host.
    static func ~= (name: String, id: TypeRef) -> Bool { id.name == name }
}
