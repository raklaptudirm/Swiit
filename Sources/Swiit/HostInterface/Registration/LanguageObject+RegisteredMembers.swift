import Foundation

// What an object's members are when its type was registered by a host: the members the host gave it, and its data as fields.

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
            (box.value as? any BridgedType)?.memberNames != nil
        else { return nil }
        var fields: [(key: Value, value: Value)] = []
        for name in memberNames {
            guard let value = member(name) else { continue }
            if case .function = value.storage { continue }
            fields.append((Value.string(name), value))
        }
        return fields
    }
}
