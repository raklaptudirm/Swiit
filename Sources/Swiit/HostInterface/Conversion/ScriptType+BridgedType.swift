import Foundation

// A type a script can use, from a Swift type that converts to and from values.

extension ScriptType {
    /// The type of a Swift type a script can use: `ScriptType(Int.self)`,
    /// `ScriptType([String].self)`; any `BridgedType`.
    public init<T: BridgedType>(_ type: T.Type) {
        self = T.scriptType
    }
}

extension ScriptType.Element {
    /// An element of a Swift type: `Element(label: "by", type: String.self)`.
    public init<T: BridgedType>(label: String? = nil, type: T.Type) {
        self.init(label: label, type: ScriptType(type))
    }
}
