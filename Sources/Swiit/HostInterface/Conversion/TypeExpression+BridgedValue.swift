import Foundation

// A type a script can use, from a Swift type that converts to and from values.

extension TypeExpression {
    /// The type of a Swift type a script can use: `TypeExpression(Int.self)`,
    /// `TypeExpression([String].self)`; any `BridgedValue`.
    public init<T: BridgedValue>(_ type: T.Type) {
        self = T.typeExpression
    }
}

extension TypeExpression.Tuple.Element {
    /// An element of a Swift type: `Tuple.Element(label: "by", type: String.self)`.
    public init<T: BridgedValue>(label: String? = nil, type: T.Type) {
        self.init(label: label, type: TypeExpression(type))
    }
}
