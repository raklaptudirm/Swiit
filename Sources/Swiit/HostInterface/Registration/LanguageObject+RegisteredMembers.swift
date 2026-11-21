import Foundation

// What an object's members are when its type was registered by a host: the members the host gave it, and its data as fields.

extension LanguageObject {
    /// The registered members of its type, unless it says.
    var memberNames: [String] {
        var seen = Set<String>()
        return (Bridge.types[typeName]?.lowered ?? [])
            .filter { !$0.isStatic && ($0.kind == .method || $0.kind == .property) }
            .map(\.name).filter { seen.insert($0).inserted }
    }

    /// The registered members of its type: a property is read, a method is a function bound to the
    /// object.
    func member(_ name: String) -> Value? {
        guard
            let member = Bridge.types[typeName]?.lowered
                .first(where: { $0.name == name && !$0.isStatic && !$0.isMutating }),
            let plain = member.plain
        else { return nil }
        let receiver = Value.object(self)
        switch member.kind {
        case .property: return try? plain(["self": receiver])
        case .method:
            return Value(
                function: ImplementedSymbol.function(
                    name: name,
                    summary: member.summary,
                    signature: Symbol.Signature(
                        parameters: member.parameters.map {
                            Symbol.Parameter(
                                label: $0.label,
                                name: $0.name,
                                type: TypeExpression($0.type)
                            )
                        },
                        returns: TypeExpression(member.returns),
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
}
