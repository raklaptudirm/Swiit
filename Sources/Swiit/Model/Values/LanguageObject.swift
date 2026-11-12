import Foundation

// Objects the language makes itself: instances, types and receivers, and function values.

/// An object the language makes itself (an instance, a type, a weak reference, a Swift value held
/// as it is, a host's value or live object held as it is). The checker types the language's by
/// what they are, and a host's by the type it registered, or by the protocol the program declares
/// under its name.
protocol LanguageObject: AnyObject, Sendable, CustomStringConvertible, CustomDebugStringConvertible
{
    /// The name `members` and error messages use, like `Job`.
    var typeName: String { get }
    /// Names of its members, for `members` and completion.
    var memberNames: [String] { get }
    /// A member answered at run time, after the registered ones; nil if there is none.
    func member(_ name: String) -> Value?
    /// What equality and hashing go by: the object itself, unless it says otherwise.
    var objectIdentity: AnyHashable { get }
}

extension LanguageObject {
    /// `dataFields` as the language's record of the object's type.
    var objectFields: Value.Record? {
        guard let fields = dataFields else { return nil }
        var record = Value.Record(typeName: typeName)
        for (key, value) in fields {
            if case .string(let name) = key.storage { record[name] = value }
        }
        return record
    }

    /// The object itself, which is what equality and hashing go by unless it says otherwise.
    var objectIdentity: AnyHashable {
        AnyHashable(ObjectIdentifier(self))
    }

    /// Its fields, as a Swift struct prints them: `Job(id: 1, …)`; or its
    /// description, for an object that isn't data.
    var debugDescription: String {
        objectFields?.debugDescription ?? description
    }
}

/// A function value: the interpreter implements this for Swiit functions, closures, overload sets
/// and key paths, and for a host's function as a value.
protocol Callable: AnyObject, Sendable, CustomStringConvertible {}

// safe: its state is touched only holding the interpreter lock
/// A mutating member's receiver, moved out of its variable for the call: nothing else holds the
/// value while the member changes it, so a collection is changed where it is, not copied whole each
/// time. The member's glue takes it out, and puts it back, changed, however the call ends.
final class ReceiverBox: LanguageObject, @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }

    /// The box, if `value` is one.
    static func of(_ value: Value) -> ReceiverBox? {
        if case .object(let box as ReceiverBox) = value.storage { box } else { nil }
    }

    /// What it holds, leaving it empty: the caller then holds the only reference.
    func take() -> Value {
        let taken = value
        value = .nothing
        return taken
    }

    func put(_ changed: Value) { value = changed }

    var typeName: String { "receiver" }
    var memberNames: [String] { [] }
    func member(_ name: String) -> Value? { nil }
    var description: String { "\(value)" }
}
