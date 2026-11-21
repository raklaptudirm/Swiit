import Foundation

// The symbols that hold a value: a global variable and a property of a type.

extension Symbol {
    /// A global: its type, and whether a script can assign to it.
    public struct Variable: SymbolProtocol {
        public var header: Header
        public var type: TypeExpression
        public var isSettable: Bool

        /// The type of this symbol as a value: the type it holds.
        public var typeExpression: TypeExpression { type }

        public init(
            name: String,
            summary: String? = nil,
            attributes: [Attribute] = [],
            type: TypeExpression,
            isSettable: Bool = false
        ) {
            header = Header(name: name, summary: summary, attributes: attributes)
            self.type = type
            self.isSettable = isSettable
        }
    }

    /// A variable that belongs to a type.
    public struct Property: SymbolProtocol {
        public var header: Header
        public var type: TypeExpression
        public var isSettable: Bool
        /// It belongs to the type itself, as a `static` member does, and not to a value of it.
        public var isStatic: Bool
        /// Reading it needs `await`: `Task.value`.
        public var isAsync: Bool
        /// The errors reading it can throw.
        public var throwing: Throwing

        /// The type of this symbol as a value: the type it holds.
        public var typeExpression: TypeExpression { type }

        public init(
            name: String,
            summary: String? = nil,
            attributes: [Attribute] = [],
            type: TypeExpression,
            isSettable: Bool = false,
            isStatic: Bool = false,
            isAsync: Bool = false,
            throwing: Throwing = .no
        ) {
            header = Header(name: name, summary: summary, attributes: attributes)
            self.type = type
            self.isSettable = isSettable
            self.isStatic = isStatic
            self.isAsync = isAsync
            self.throwing = throwing
        }
    }
}
