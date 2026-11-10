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
}

extension LanguageObject {
    /// The registered members of its type, unless it says.
    var memberNames: [String] {
        var seen = Set<String>()
        return (Bridge.types[typeName]?.members ?? [])
            .filter { !$0.isStatic && ($0.kind == .method || $0.kind == .property) }
            .map(\.name).filter { seen.insert($0).inserted }
    }

    /// The registered members of its type: a property is read, a method is a function bound to the
    /// object.
    func member(_ name: String) -> Value? {
        guard
            let member = Bridge.types[typeName]?.members
                .first(where: { $0.name == name && !$0.isStatic && !$0.isMutating }),
            let plain = member.plain
        else { return nil }
        let receiver = Value.object(self)
        switch member.kind {
        case .property: return try? plain(["self": receiver])
        case .method:
            return Value(
                HostSymbol.function(
                    name: name,
                    summary: member.summary,
                    signature: Symbol.Function(
                        parameters: member.parameters.map {
                            Symbol.Parameter(
                                label: $0.label,
                                name: $0.name,
                                type: ScriptType($0.type)
                            )
                        },
                        returns: ScriptType(member.returns),
                        isThrowing: member.isThrowing
                    ),
                    call: { arguments in
                        var arguments = arguments
                        arguments["self"] = receiver
                        return try plain(arguments)
                    }
                )
            )
        default: return nil
        }
    }

    /// Its data as named fields, which a host lays out as a record (a table, JSON): every member that isn't
    /// a method. What the language makes itself (a type, an instance, a Swift value held as it is)
    /// has none: it is one value, like a `FileSize`.
    var dataFields: [(key: Value, value: Value)]? {
        // A held value is data if it names its members: a parsed object's keys, a job's fields.
        guard let box = self as? SwiftValue,
            (box.value as? any ScriptConvertible)?.memberNames != nil
        else { return nil }
        var fields: [(key: Value, value: Value)] = []
        for name in memberNames {
            guard let value = member(name) else { continue }
            if case .function = value.storage { continue }
            fields.append((Value.string(name), value))
        }
        return fields
    }

    /// `dataFields` as the language's record of the object's type.
    var objectFields: Value.Record? {
        guard let fields = dataFields else { return nil }
        var record = Value.Record(typeName: typeName)
        for (key, value) in fields {
            if case .string(let name) = key.storage { record[name] = value }
        }
        return record
    }

    /// What equality and hashing go by: the object itself, and for a Swift value held as it is,
    /// the value (when it is `Hashable`).
    var objectIdentity: AnyHashable {
        (self as? SwiftValue)?.identity ?? AnyHashable(ObjectIdentifier(self))
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

/// A mutating member's receiver, moved out of its variable for the call: nothing else holds the
/// value while the member changes it, so a collection is changed where it is, not copied whole each
/// time. The member's glue takes it out, and puts it back, changed, however the call ends.
final class ReceiverBox: LanguageObject, @unchecked Sendable {  // safe: its state is touched only holding the interpreter lock
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
