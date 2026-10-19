import Foundation

/// What a function that carries on past a failure gives: its result, and
/// what went wrong on the way. The shell reports each error as an error in
/// one item, as it does for `ls` on a directory it can't read, with the
/// function's name before the error's description, and goes on with the
/// result.
@_spi(Layer) public struct Partial<Value> {
    public var value: Value
    public var errors: [any Error]

    public init(_ value: Value, errors: [any Error] = []) {
        self.value = value
        self.errors = errors
    }
}

// MARK: Fields by name

/// How a value's field is read by name, set by the shell for the length of a
/// call that takes a key path: the shell knows what a record, a struct or an
/// object has.
///
/// It belongs to the thread that set it, because a call runs on one thread
/// from start to finish and interpreters run on threads of their own: a
/// reader shared by all would be another interpreter's.
@_spi(Layer) public enum FieldAccess {
    private final class Box {
        let reader: (Value, String) -> Value
        init(_ reader: @escaping (Value, String) -> Value) { self.reader = reader }
    }

    private static let key = "SwiitKit.FieldAccess.reader"

    public static var reader: ((Value, String) -> Value)? {
        get { (Thread.current.threadDictionary[key] as? Box)?.reader }
        set { Thread.current.threadDictionary[key] = newValue.map(Box.init) }
    }
}

extension Value {
    /// A field by name, nil as `.nothing`: what a key path over values
    /// (`\Value.[field: "size"]`) reads, so a Swift function taking a
    /// `KeyPath<Element, V>` works on Swiit's values as on Swift's.
    @_spi(Layer) public subscript(field name: String) -> Value {
        FieldAccess.reader?(self, name) ?? .nothing
    }
}
