import Foundation
import SwiftSyntax
import Synchronization

// A reference to a type: the declaration it is, not the name it goes by.

/// Names one type. `register` returns one, `TypeRef(named:in:)` finds one, `Value.typeRef` has one, and
/// `TypeExpression.named` and `Value.isInstance(of:)` take one. A host gets a reference from the
/// interpreter (`register`, `TypeRef(named:in:)`, `Symbol.typeRef`, a value's `typeRef`) and makes one
/// itself only for a Swift type it registers (`init(nativeType:)`).
///
/// A reference is one of two kinds.
///
/// - **Declared**: a type a script declares. It names one declaration, made once in this process.
///   Declaring `struct Point` again makes a new type with a new reference, and the old reference
///   keeps naming the old type. A host cannot make one. It comes from the interpreter, so a
///   misspelling cannot name a declaration, and a reference from another interpreter names nothing
///   here.
/// - **Native**: a Swift type the host or the core provides (`Int`, `Array`, a registered
///   `FileSize`, an encoded Swift value), named by what `String(describing:)` gives for it, which
///   has no module in it. Native types are process-wide and one per name, as the registry that holds
///   them is: two Swift types of one name in different modules collide, and an encoded value
///   carries only the name. A reference of this kind may name nothing (a type that is not
///   registered, or an encoded value's), and `TypeRef.symbol(in:)` then returns nil.
///
/// A generic parameter (`Element`) is not a reference to a type. It stands where one would be, and
/// `TypeExpression.parameter` says so.
///
/// Two references are equal when they are the same kind and name the same declaration or have the
/// same name. They do not outlive the process.
public struct TypeRef: Sendable, Hashable, CustomStringConvertible {
    enum Kind: Sendable, Hashable { case declared(UInt64), native }

    let kind: Kind
    /// The type's name as a script writes it: for display, not identity. Two IDs can share a
    /// name and be different types (a type declared again), and a native type's reference is its name alone.
    public let name: String

    private init(_ kind: Kind, _ name: String) {
        self.kind = kind
        self.name = name
    }

    static func native(_ name: String) -> TypeRef { TypeRef(.native, name) }

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
    /// before there is an interpreter to ask or before the type is registered: a `typeExpression`
    /// that is a static property, a type's own members that name it. It equals the reference
    /// `register` gives for the type of that name, and the same name's in another interpreter,
    /// and can never equal a script's type. Everywhere else, pass around what `register` gave
    /// back, or ask `TypeRef(named:in:)`.
    public init(nativeType name: String) { self.init(.native, name) }

    public var description: String { name }

    public static func == (lhs: TypeRef, rhs: TypeRef) -> Bool {
        switch (lhs.kind, rhs.kind) {
        case (.declared(let a), .declared(let b)): a == b
        case (.native, .native): lhs.name == rhs.name
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch kind {
        case .declared(let token): hasher.combine(token)
        case .native: hasher.combine(name)
        }
    }

    /// Swift's own, which scripts have and hosts match on.
    public static let any = TypeRef.native("Any")
    public static let bool = TypeRef.native("Bool")
    public static let int = TypeRef.native("Int")
    public static let double = TypeRef.native("Double")
    public static let string = TypeRef.native("String")
    public static let array = TypeRef.native("Array")
    static let arraySlice = TypeRef.native("ArraySlice")
    static let set = TypeRef.native("Set")
    public static let dictionary = TypeRef.native("Dictionary")
    public static let optional = TypeRef.native("Optional")
    public static let function = TypeRef.native("Function")
    public static let keyPath = TypeRef.native("KeyPath")
    public static let sequence = TypeRef.native("Sequence")
    public static let rawRepresentable = TypeRef.native("RawRepresentable")

    /// Lets a pattern say `case .named("Array", …)` inside the module, which a literal
    /// conformance would offer to every host.
    static func ~= (name: String, reference: TypeRef) -> Bool { reference.name == name }
}
