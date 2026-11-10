import Foundation
import SwiftSyntax
import Synchronization

// The identity of a symbol: the declaration it is, not the name it goes by.

extension Symbol {
    /// Names a type, or stands where one would be: what `register` gives back, what
    /// `Symbol.ID(named:in:)` finds, what `Value.typeID` has, and what `ScriptType.named` and
    /// `Value.isInstance(of:)` take. A host gets one from the interpreter (`register`,
    /// `Symbol.ID(named:in:)`, `Symbol.id`, a value's `typeID`), and mints one only for a Swift type it
    /// registers (`init(hostType:)`).
    ///
    /// An ID is one of three kinds:
    /// - **Declared**: a type a script declares. It names one declaration, made once in this
    ///   process. Declaring `struct Point` again makes a new type with a new ID, and the old ID
    ///   keeps naming the old one. A host cannot make one; it comes from the interpreter, so a
    ///   misspelling cannot name a declaration. An ID from another interpreter is just one this
    ///   interpreter never made, and names nothing.
    /// - **Host**: a Swift type the host or the core provides (`Int`, `Array`, a registered
    ///   `FileSize`, an encoded Swift value), by the name `String(describing:)` gives the Swift
    ///   type, which has no module in it. Host types are process-wide and one per name, as the
    ///   registry they live in is: two Swift types of one name in different modules collide, and an
    ///   encoded value carries only the name. An ID of this kind may name nothing (a type not
    ///   registered, or an encoded value's), and `Symbol.ID.symbol(in:)` then gives nil.
    /// - **Parameter**: a generic parameter (`Element`), by name, with nothing declared under it.
    ///
    /// IDs are equal when they are the same kind and the same declaration, or the same name. They
    /// do not outlive the process.
    public struct ID: Sendable, Hashable, CustomStringConvertible {
        enum Kind: Sendable, Hashable { case declared(UInt64), host, parameter }

        let kind: Kind
        /// The type's name as a script writes it: for display, not identity. Two IDs can share a
        /// name and be different types (a type declared again), and a host ID is its name alone.
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

        static func host(_ name: String) -> ID { ID(.host, name) }
        static func parameter(_ name: String) -> ID { ID(.parameter, name) }

        /// A new declaration's ID, from a counter shared by the process.
        static func declare(_ name: String) -> ID {
            ID(
                .declared(
                    counter.withLock {
                        $0 += 1; return $0
                    }
                ),
                name
            )
        }
        private static let counter = Mutex<UInt64>(0)

        /// The ID of a Swift type the host is about to register, for the places that need it
        /// before there is an interpreter to ask or before the type is registered: a `scriptType`
        /// that is a static property, a type's own members that name it. It equals the ID
        /// `register` gives for the type of that name, and the same name's in another interpreter,
        /// and can never equal a script's type. Everywhere else, pass around what `register` gave
        /// back, or ask `Symbol.ID(named:in:)`.
        public init(hostType name: String) { self.init(.host, name) }

        public var description: String { name }

        public static func == (lhs: ID, rhs: ID) -> Bool {
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
        public static let any = ID.host("Any")
        public static let bool = ID.host("Bool")
        public static let int = ID.host("Int")
        public static let double = ID.host("Double")
        public static let string = ID.host("String")
        public static let array = ID.host("Array")
        public static let arraySlice = ID.host("ArraySlice")
        public static let set = ID.host("Set")
        public static let dictionary = ID.host("Dictionary")
        public static let optional = ID.host("Optional")
        public static let function = ID.host("Function")
        public static let keyPath = ID.host("KeyPath")
        public static let sequence = ID.host("Sequence")
        public static let rawRepresentable = ID.host("RawRepresentable")

        /// Lets a pattern say `case .named("Array", …)` inside the module, which a literal
        /// conformance would offer to every host.
        static func ~= (name: String, id: ID) -> Bool { id.name == name }
    }
}
