import Foundation

// What a type a host wrote becomes for the checker and the interpreter: its members lowered.

extension ImplementedType {
    /// What the type needs of its generic parameters to conform to the protocol of Swift's called
    /// `name`; nil when it does not conform.
    func conformance(named name: String) -> [Symbol.GenericParameter]? {
        conformances[TypeRef(nativeType: name)]
    }

    /// The names of the protocols it conforms to.
    var conformanceNames: [String] { conformances.keys.map(\.name) }

    /// The generic parameters' names, which the checker binds.
    var genericParameterNames: [String] { genericParameters.map(\.name) }
    /// The types it binds its protocols' associated types to: `Element` is `String` for a sequence of
    /// text.
    var associatedTypes: [String: TypeExpression] {
        var found: [String: TypeExpression] = [:]
        for member in members {
            if case .associatedType(let associated) = member.symbol,
                case .binding(let type) = associated.role
            {
                found[member.name] = type
            }
        }
        return found
    }

    /// The associated types as the checker writes them.
    var checkedAssociatedTypes: [String: TypeExpression] {
        associatedTypes.mapValues(\.byText)
    }

    /// It, with its members lowered. A type of the core is bridged: its members are not a host's own,
    /// so none is called without an interpreter and a host's member of the same shape takes its place
    /// (a generated description is one); its representation is the one the interpreter stores itself, if it is one of those.
    func lowering(ofTheCore core: Bool = false) -> ImplementedType {
        var made = self
        made.lowered = members.flatMap {
            BridgedMember.members(of: $0, in: name, from: core ? .bridged : .host)
        }
        if core { made.representation = Representation(named: name) ?? .held }
        return made
    }

    /// It, with members written by hand too, where the generator can't make them. A host's own member
    /// (one a native type registered) takes the place of a bridged one of the same shape, which is how a
    /// host says how a type shows; one registered twice is not added again.
    func adding(_ extra: [BridgedMember]) -> ImplementedType {
        func same(_ a: BridgedMember, _ b: BridgedMember) -> Bool {
            a.kind == b.kind && a.name == b.name && a.isStatic == b.isStatic
                && a.parameters.map(\.label) == b.parameters.map(\.label)
                && a.parameters.map(\.type) == b.parameters.map(\.type)
        }
        let kept = lowered.filter { old in
            !extra.contains { new in new.origin == .host && old.origin == .bridged && same(old, new)
            }
        }
        let extra = extra.filter { new in !kept.contains { same($0, new) } }
        guard !extra.isEmpty || kept.count != lowered.count else { return self }
        var made = self
        made.lowered = kept + extra
        return made
    }

    /// It, conforming to `protocols` too, whatever its generic parameters are.
    func conforming(to protocols: [String]) -> ImplementedType {
        guard !protocols.isEmpty else { return self }
        var made = self
        for name in protocols { made.symbol.conformances[TypeRef(nativeType: name)] = [] }
        return made
    }
}

extension BridgedMember {
    /// The members of a Swift type of the core's, written as a host writes its own: bridged, not
    /// a host's, so none is called without an interpreter and a host's member of the same shape
    /// takes its place.
    static func bridged(_ symbols: [ImplementedSymbol], in typeName: String) -> [BridgedMember] {
        symbols.flatMap { members(of: $0, in: typeName, from: .bridged) }
    }

    /// The parameters a script sees, from those a host declared.
    private static func parameters(_ function: Symbol.Signature) -> [Parameter] {
        function.parameters.map { Parameter(described: $0) }
    }

    /// A member that changes its receiver, as the glue for a Swift member does: a variable's value
    /// is moved into a box for the call, which takes the changed one back however the call
    /// ends, and a value that is not in one comes back with the result.
    @Sendable private static func mutating(
        _ given: Value,
        _ body: (_ receiver: inout Value) throws -> Value
    ) throws -> Value {
        let mover = ReceiverBox.of(given)
        var receiver = mover?.take() ?? given
        let result: Value
        do { result = try body(&receiver) } catch {
            mover?.put(receiver)
            throw error
        }
        mover?.put(receiver)
        return .list([result, mover == nil ? receiver : .nothing])
    }

    /// What a host wrote as one lowered member, which `members(of:in:)` makes one or two of.
    private struct Lowering {
        let member: ImplementedSymbol
        let typeName: String
        let origin: BridgedMember.Origin

        func callAsFunction(
            _ kind: BridgedMember.Kind,
            isStatic: Bool = false,
            name: String? = nil,
            parameters: [Parameter] = [],
            returns: TypeExpression,
            function: Symbol.Signature? = nil,
            isMutating: Bool = false,
            call: @escaping @Sendable (_ receiver: Value, _ arguments: [Value]) throws -> Value
        ) -> BridgedMember {
            BridgedMember(
                kind: kind,
                name: name ?? member.name,
                isStatic: isStatic,
                parameters: parameters,
                returns: returns,
                generics: function?.generics ?? [],
                // `throws(Failure)` is the member's typedThrows: it throws unless Failure is `Never`.
                isThrowing: function?.throwing == .any,
                isRethrowing: function?.throwing == .rethrowing,
                isMutating: isMutating,
                attributes: member.symbol.attributes,
                summary: member.summary,
                origin: origin,
                typeName: typeName,
                call: call,
                parameterDocs: Dictionary(
                    (function?.parameters ?? [])
                        .compactMap { parameter in
                            parameter.documentation.map { (parameter.name, $0) }
                        },
                    uniquingKeysWith: { first, _ in first }
                ),
                effect: function?.isAsync == true ? .async : .sync,
                typedThrows: function.flatMap { function in
                    if case .throwing(.typed(let type)) = function.throwing {
                        type.description
                    } else {
                        nil
                    }
                }
            )
        }
    }

    /// What a script can call, from what a host wrote: a settable property is a property and its
    /// setter.
    static func members(
        of member: ImplementedSymbol,
        in typeName: String,
        from origin: Origin
    ) -> [BridgedMember] {
        let symbol = member.symbol
        let make = Lowering(member: member, typeName: typeName, origin: origin)
        switch (symbol, member.body) {
        case (.method(let method), .method(let body)):
            let function = method.signature
            return [
                make(
                    .method,
                    parameters: parameters(function),
                    returns: function.returns.byText,
                    function: function,
                    call: body
                )
            ]
        case (.method(let method), .mutatingMethod(let body)):
            let function = method.signature
            return [
                make(
                    .method,
                    parameters: parameters(function),
                    returns: function.returns.byText,
                    function: function,
                    isMutating: true
                ) { receiver, arguments in
                    try mutating(receiver) { try body(&$0, arguments) }
                }
            ]
        case (.method(let method), .staticMethod(let body)):
            let function = method.signature
            return [
                make(
                    .method,
                    isStatic: true,
                    parameters: parameters(function),
                    returns: function.returns.byText,
                    function: function
                ) { _, arguments in try body(arguments) }
            ]
        case (.property(let property), .property(let get)):
            return [
                make(
                    .property,
                    returns: property.type.byText,
                    function: Symbol.Signature(
                        returns: property.type,
                        throwing: property.throwing,
                        isAsync: property.isAsync
                    )
                ) { receiver, _ in try get(receiver) }
            ]
        case (.property(let property), .settableProperty(let get, let set)):
            let type = property.type
            return [
                make(.property, returns: type.byText) { receiver, _ in try get(receiver) },
                make(
                    .setter,
                    parameters: [
                        Parameter(label: nil, name: "newValue", type: type.byText)
                    ],
                    returns: .void,
                    isMutating: true
                ) { receiver, arguments in
                    try mutating(receiver) {
                        $0 = try set($0, arguments[0])
                        return .nothing
                    }
                },
            ]
        case (.property(let property), .staticProperty(let get)):
            return [
                make(
                    .property,
                    isStatic: true,
                    returns: property.type.byText
                ) { _, _ in try get() }
            ]
        case (.initializer(let initializer), .initializer(let body)):
            let function = initializer.signature
            return [
                make(
                    .initializer,
                    isStatic: true,
                    name: "init",
                    parameters: parameters(function),
                    returns: function.returns.byText,
                    function: function
                ) { _, arguments in try body(arguments) }
            ]
        case (.associatedType, .associatedType):
            // It names a type, and nothing in it runs.
            return []
        default:
            preconditionFailure("\(member.name) is not a member of a type")
        }
    }
}
