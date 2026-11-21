import Foundation

// What a type a host wrote becomes for the checker and the interpreter: its members lowered.

extension TypeImplementation {
    /// The generic parameters' names, which the checker binds.
    var genericParameterNames: [String] { declaration.genericParameters.map(\.name) }
    /// The types it binds its protocols' associated types to: `Element` is `String` for a sequence of
    /// text.
    var associatedTypes: [String: TypeExpression] {
        var found: [String: TypeExpression] = [:]
        for member in members {
            if case .member(.associatedType(.binding(let type))) = member.symbol.kind {
                found[member.name] = type
            }
        }
        return found
    }

    /// The associated types as the checker writes them.
    var annotatedAssociatedTypes: [String: TypeAnnotation] {
        associatedTypes.mapValues(TypeAnnotation.init)
    }

    /// It, with its members lowered. A type of the core is bridged: its members are not a host's own,
    /// so none is called without an interpreter and a host's member of the same shape takes its place
    /// (a generated description is one); its representation is the one the interpreter stores itself, if it is one of those.
    func lowering(ofTheCore core: Bool = false) -> TypeImplementation {
        var made = self
        made.lowered = members.flatMap { BridgedMember.members(of: $0, in: name) }
        if core {
            made.lowered = made.lowered.map {
                var member = $0; member.plain = nil; return member
            }
            made.representation = Representation(named: name) ?? .held
        }
        return made
    }

    /// It, with members written by hand too, where the generator can't make them. A host's own member
    /// (one a native type registered) takes the place of a bridged one of the same shape, which is how a
    /// host says how a type shows; one registered twice is not added again.
    func adding(_ extra: [BridgedMember]) -> TypeImplementation {
        func same(_ a: BridgedMember, _ b: BridgedMember) -> Bool {
            a.kind == b.kind && a.name == b.name && a.isStatic == b.isStatic
                && a.parameters.map(\.label) == b.parameters.map(\.label)
                && a.parameters.map(\.type) == b.parameters.map(\.type)
        }
        let kept = lowered.filter { old in
            !extra.contains { new in new.plain != nil && old.plain == nil && same(old, new) }
        }
        let extra = extra.filter { new in !kept.contains { same($0, new) } }
        guard !extra.isEmpty || kept.count != lowered.count else { return self }
        var made = self
        made.lowered = kept + extra
        return made
    }

    /// It, conforming to `protocols` too, whatever its generic parameters are.
    func conforming(to protocols: [String]) -> TypeImplementation {
        guard !protocols.isEmpty else { return self }
        var made = self
        for name in protocols { made.declaration.conformances[name] = [] }
        return made
    }
}

extension BridgedMember {
    /// The members of a Swift type of the core's, written as a host writes its own: bridged, not
    /// a host's, so none is called without an interpreter and a host's member of the same shape
    /// takes its place.
    static func bridged(_ symbols: [SymbolImplementation], in typeName: String) -> [BridgedMember] {
        symbols.flatMap { members(of: $0, in: typeName) }
            .map {
                var member = $0; member.plain = nil; return member
            }
    }

    /// The parameters a script sees, from those a host declared.
    private static func parameters(_ function: Symbol.Function) -> [Parameter] {
        function.parameters.map { Parameter(described: $0) }
    }

    /// The arguments in declared order, from what a call bound by name.
    private static func ordered(_ function: Symbol.Function) -> @Sendable (Arguments) -> [Value] {
        let slots = function.parameters.map { parameter -> (String, Value) in
            if case .defaulted(.value(let value)) = parameter.arity {
                return (parameter.name, value)
            }
            return (parameter.name, .nothing)
        }
        return { arguments in slots.map { arguments[$0.0] ?? $0.1 } }
    }

    /// A member that changes its receiver, as the glue for a Swift member does: a variable's value
    /// is moved into a box for the call, which takes the changed one back however the call
    /// ends, and a value that is not in one comes back with the result.
    @Sendable private static func mutating(
        _ arguments: Arguments,
        _ body: (_ receiver: inout Value) throws -> Value
    ) throws -> Value {
        let given = arguments["self"] ?? .nothing
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

    // swiftlint:disable function_body_length - a long walk over every case; splitting it is item 17 of Docs/agenda.md
    /// What a script can call, from what a host wrote: a settable property is a property and its
    /// setter.
    static func members(of member: SymbolImplementation, in typeName: String) -> [BridgedMember] {
        let symbol = member.symbol
        func make(
            _ kind: BridgedMember.Kind,
            isStatic: Bool = false,
            name: String? = nil,
            parameters: [Parameter] = [],
            returns: TypeAnnotation,
            function: Symbol.Function? = nil,
            isMutating: Bool = false,
            call: @escaping @Sendable (Arguments) throws -> Value
        ) -> BridgedMember {
            var made = BridgedMember(
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
                attributes: symbol.attributes,
                summary: member.summary,
                // An error it throws is one a script can catch, as a function's is.
                body: .native { interpreter, arguments in
                    do { return try call(arguments) } catch {
                        throw interpreter.hostFailure(error, in: "\(typeName).\(member.name)")
                    }
                },
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
            made.plain = call
            return made
        }
        switch (symbol.kind, member.body) {
        case (.member(.method(let method)), .method(let body)):
            let function = method.function, order = ordered(function)
            return [
                make(
                    .method,
                    parameters: parameters(function),
                    returns: TypeAnnotation(function.returns),
                    function: function
                ) { try body($0["self"] ?? .nothing, order($0)) }
            ]
        case (.member(.method(let method)), .mutatingMethod(let body)):
            let function = method.function, order = ordered(function)
            return [
                make(
                    .method,
                    parameters: parameters(function),
                    returns: TypeAnnotation(function.returns),
                    function: function,
                    isMutating: true
                ) { arguments in
                    try mutating(arguments) { try body(&$0, order(arguments)) }
                }
            ]
        case (.member(.method(let method)), .staticMethod(let body)):
            let function = method.function, order = ordered(function)
            return [
                make(
                    .method,
                    isStatic: true,
                    parameters: parameters(function),
                    returns: TypeAnnotation(function.returns),
                    function: function
                ) { try body(order($0)) }
            ]
        case (.member(.property(let property)), .property(let get)):
            return [
                make(
                    .property,
                    returns: TypeAnnotation(property.variable.type),
                    function: Symbol.Function(
                        returns: property.variable.type,
                        throwing: property.throwing,
                        isAsync: property.isAsync
                    )
                ) { try get($0["self"] ?? .nothing) }
            ]
        case (.member(.property(let property)), .settableProperty(let get, let set)):
            let type = property.variable.type
            return [
                make(.property, returns: TypeAnnotation(type)) { try get($0["self"] ?? .nothing) },
                make(
                    .setter,
                    parameters: [
                        Parameter(label: nil, name: "newValue", type: TypeAnnotation(type))
                    ],
                    returns: .void,
                    isMutating: true
                ) { arguments in
                    try mutating(arguments) {
                        $0 = try set($0, arguments["newValue"] ?? .nothing)
                        return .nothing
                    }
                },
            ]
        case (.member(.property(let property)), .staticProperty(let get)):
            return [
                make(
                    .property,
                    isStatic: true,
                    returns: TypeAnnotation(property.variable.type)
                ) { _ in try get() }
            ]
        case (.member(.initializer(let function)), .initializer(let body)):
            let order = ordered(function)
            return [
                make(
                    .initializer,
                    isStatic: true,
                    name: "init",
                    parameters: parameters(function),
                    returns: TypeAnnotation(function.returns),
                    function: function
                ) { try body(order($0)) }
            ]
        case (.member(.associatedType), .associatedType):
            // It names a type, and nothing in it runs.
            return []
        default:
            preconditionFailure("\(member.name) is not a member of a type")
        }
    }
    // swiftlint:enable function_body_length
}
