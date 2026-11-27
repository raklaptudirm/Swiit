import Foundation

// What an object's members are when its type was registered by a host: the members the host gave it, and its data as fields.

extension LanguageObject {
    /// The registered members of its type, unless it says.
    var memberNames: [String] {
        var seen = Set<String>()
        return (Bridge.current[typeName]?.lowered ?? [])
            .filter { !$0.isStatic && ($0.kind == .method || $0.kind == .property) }
            .map(\.name).filter { seen.insert($0).inserted }
    }

    /// The registered members of its type: a property is read, a method is a function bound to the
    /// object.
    func member(_ name: String) -> Value? {
        guard
            let member = Bridge.current[typeName]?.lowered
                .first(where: {
                    $0.name == name && !$0.isStatic && !$0.isMutating && $0.origin == .host
                })
        else { return nil }
        let receiver = Value.object(self)
        switch member.kind {
        case .property: return try? member.call(receiver, [])
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
                                type: $0.type.byText
                            )
                        },
                        returns: member.returns.byText,
                        isThrowing: member.isThrowing
                    ),
                    body: { arguments in try member.call(receiver, arguments) }
                )
            )
        default: return nil
        }
    }
}
