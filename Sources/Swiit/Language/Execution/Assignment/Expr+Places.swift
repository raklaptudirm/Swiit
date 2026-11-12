extension Expr {
    /// The place `xs[i]` or `d[key]` names, when the checker has written it as the bridged
    /// subscript it calls: a list's or a dictionary's entry is a place the interpreter changes in
    /// place, and reading it through the bridge must not make it a value.
    var subscriptPlace: (receiver: Expr, index: Expr)? {
        guard case .bridged(let type, let member, let receiver?, let arguments) = self,
            arguments.count == 1, Value.Builtin(named: type) != nil,
            let bridged = Bridge.types[type], bridged.members.indices.contains(member),
            bridged.members[member].kind == .method, bridged.members[member].name == "subscript"
        else { return nil }
        return (receiver, arguments[0].value)
    }
}

extension Interpreter {
    /// `xs[i]`, `d[key]`: what the bridged subscript gives. A list's entry at a position it has and a
    /// dictionary's entry are read where the value is, as the glue would give them; anything
    /// else goes through the glue, which says what is wrong with the index.
    func readSubscript(
        of place: (receiver: Expr, index: Expr),
        type: String,
        member: Int
    ) throws -> Value {
        let receiver = try evaluate(place.receiver)
        let index = try evaluate(place.index)
        switch (receiver.storage, index.storage) {
        case (.list(let items), .int(let position)) where items.indices.contains(position):
            return items[position]
        case (.dictionary(let entries), _):
            return entries[index] ?? .nothing
        default:
            return try runBridged(
                type,
                member,
                receiver: .literal(receiver),
                [Argument(value: .literal(index))]
            )
        }
    }
}
