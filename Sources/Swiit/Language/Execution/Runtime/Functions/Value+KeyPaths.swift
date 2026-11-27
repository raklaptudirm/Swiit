import Foundation

// A key path as a value.

extension Value {
    /// A key path: `Value(keyPath: ["owner", "name"])` is `\.owner.name`, which reads the members
    /// in turn from a value and is a function of it where one is wanted, as in `xs.map(\.name)`.
    public init(keyPath path: [String]) {
        self = .function(KeyPathValue(path: path))
    }
}
