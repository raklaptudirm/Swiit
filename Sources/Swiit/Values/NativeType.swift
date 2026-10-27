import Foundation

/// What `HostTypeBuilder` writes and `register` makes a type of: a name and its members, and what
/// its Swift type says of itself.
struct HostType: Sendable {
    var name: String
    var members: [HostSymbol]
    /// The protocols its Swift type conforms to, of those Swiit knows: `Equatable`, `Hashable`,
    /// `Comparable`, `Sequence`. A builder finds them from the type.
    var conformances: [String] = []
    /// What its associated types are: `Element` is `String` for a sequence of text.
    var associatedTypes: [String: ScriptType] = [:]
    /// A value from text, where text gives a word and the type is wanted.
    var parse: (@Sendable (String) -> Value?)?
    /// A value from a text literal, where a script writes `"…"` and the type is wanted
    /// (`let column: DisplayColumn = "name"`).
    var literal: (@Sendable (String) -> Value?)?

    init(name: String, members: [HostSymbol] = []) {
        self.name = name
        self.members = members
    }
}

extension Value {
    /// The name a Swift type is registered under by default: its own, without its generic arguments.
    static func hostName(of type: Any.Type) -> String {
        String(String(describing: type).prefix { $0 != "<" })
    }

    /// The Swift value this holds, if it holds one of type `T`.
    func unboxing<T>(_: T.Type = T.self) throws -> T {
        try SwiftValue.unbox(T.self, self)
    }
}

extension Interpreter {
    /// Makes a Swift value type one scripts can use. Registering a type again adds the members it
    /// lacks. It gives the type's ID, which is `Symbol.ID(hostType: name)`: the same promises hold
    /// of it, and of what they leave out.
    @discardableResult
    public func register<T>(_ builder: HostTypeBuilder<T>) -> Symbol.ID { register(builder.type) }

    @discardableResult
    func register(_ type: HostType) -> Symbol.ID {
        var bridged = BridgedType(type)
        // A sequence has what a list has, over its items: `sorted`, `map`, `max`, `joined`
        // (`Output`'s lines).
        if type.conformances.contains("Sequence"), let element = type.associatedTypes["Element"] {
            bridged = bridged.adding(
                itemMembers(
                    of: TypeAnnotation(element),
                    excluding: Set(type.members.map(\.name))
                )
            )
        }
        Bridge.register([bridged])
        withMainTask {
            scopes[0].bindings[type.name] = Binding(
                value: .object(BridgedTypeName(type.name)),
                mutable: false
            )
        }
        return .host(type.name)
    }
}

extension Interpreter {
    /// A list's members, which read their receiver without changing it, made members of a sequence:
    /// they take its items as the list they work on.
    func itemMembers(of element: TypeAnnotation, excluding own: Set<String>) -> [BridgedMember] {
        guard let array = Bridge.types["Array"] else { return [] }
        let checker = TypeChecker(interpreter: self)
        let bindings = ["Element": element]
        return array.members
            .filter {
                !$0.isStatic && !$0.isMutating && ($0.kind == .method || $0.kind == .property)
                    && !own.contains($0.name)
            }
            .map { member in
                let body: FunctionBody
                if case .native(let call) = member.body {
                    body = .native { interpreter, arguments in
                        var arguments = arguments
                        if let receiver = arguments["self"],
                            let items = Interpreter.items(of: receiver)
                        {
                            arguments["self"] = .list(Array(IteratorSequence(items)))
                        }
                        return try call(interpreter, arguments)
                    }
                } else {
                    body = member.body
                }
                return BridgedMember(
                    kind: member.kind,
                    name: member.name,
                    isStatic: false,
                    parameters: member.parameters.map {
                        var made = $0; made.type = checker.substitute($0.type, bindings);
                        return made
                    },
                    returns: checker.substitute(member.returns, bindings),
                    generics: member.generics,
                    isThrowing: member.isThrowing,
                    isRethrowing: member.isRethrowing,
                    isMutating: false,
                    attributes: member.attributes,
                    summary: member.summary,
                    body: body,
                    parameterDocs: member.parameterDocs,
                    effect: member.effect,
                    typedThrows: member.typedThrows
                )
            }
    }
}

extension BridgedType {
    init(_ type: HostType) {
        self.init(
            name: type.name,
            genericParameters: [],
            conformances: Dictionary(uniqueKeysWithValues: type.conformances.map { ($0, []) }),
            associatedTypes: type.associatedTypes.mapValues(TypeAnnotation.init),
            parse: type.parse,
            literal: type.literal,
            arrayLiteral: nil,
            members: type.members.flatMap { BridgedMember.members(of: $0, in: type.name) }
        )
    }
}

extension BridgedMember {
    /// What a script can call, from what a host wrote: a settable property is a property and its
    /// setter.
    static func members(of member: HostSymbol, in typeName: String) -> [BridgedMember] {
        let symbol = member.symbol
        func parameters(_ function: Symbol.Function) -> [Parameter] {
            function.parameters.map { parameter in
                var made = Parameter(
                    label: parameter.label,
                    name: parameter.name,
                    type: TypeAnnotation(parameter.type)
                )
                switch parameter.arity {
                case .required: break
                case .variadic: made.variadic = true
                case .defaulted(.value(let value)): made.defaultValue = .literal(value)
                case .defaulted(.computed): made.externalDefault = "…"
                }
                return made
            }
        }
        /// The arguments in declared order, from what a call bound by name.
        func ordered(_ function: Symbol.Function) -> @Sendable ([String: Value]) -> [Value] {
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
        @Sendable func mutating(
            _ arguments: [String: Value],
            _ body: (_ receiver: Value) throws -> (result: Value, receiver: Value)
        ) throws -> Value {
            let given = arguments["self"] ?? .nothing
            let mover = ReceiverBox.of(given)
            let taken = mover?.take() ?? given
            do {
                let (result, receiver) = try body(taken)
                mover?.put(receiver)
                return .list([result, mover == nil ? receiver : .nothing])
            } catch {
                mover?.put(taken)
                throw error
            }
        }
        func make(
            _ kind: BridgedMember.Kind,
            isStatic: Bool = false,
            name: String? = nil,
            parameters: [Parameter] = [],
            returns: TypeAnnotation,
            function: Symbol.Function? = nil,
            isMutating: Bool = false,
            call: @escaping @Sendable ([String: Value]) throws -> Value
        ) -> BridgedMember {
            var made = BridgedMember(
                kind: kind,
                name: name ?? member.name,
                isStatic: isStatic,
                parameters: parameters,
                returns: returns,
                generics: function?.generics ?? [],
                isThrowing: function?.isThrowing ?? false,
                isRethrowing: false,
                isMutating: isMutating,
                attributes: symbol.attributes,
                summary: member.summary,
                // An error it throws is one a script can catch, as a function's is.
                body: .native { interpreter, arguments in
                    do { return try call(arguments) } catch {
                        throw interpreter.hostFailure(error, in: "\(typeName).\(member.name)")
                    }
                },
                effect: function?.isAsync == true ? .async : .sync
            )
            made.plain = call
            return made
        }
        switch (symbol.kind, member.body) {
        case (.method(let method), .method(let body)):
            let function = method.function, order = ordered(function)
            return [
                make(
                    .method,
                    parameters: parameters(function),
                    returns: TypeAnnotation(function.returns),
                    function: function
                ) { try body($0["self"] ?? .nothing, order($0)) }
            ]
        case (.method(let method), .mutatingMethod(let body)):
            let function = method.function, order = ordered(function)
            return [
                make(
                    .method,
                    parameters: parameters(function),
                    returns: TypeAnnotation(function.returns),
                    function: function,
                    isMutating: true
                ) { arguments in
                    try mutating(arguments) { try body($0, order(arguments)) }
                }
            ]
        case (.method(let method), .staticMethod(let body)):
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
        case (.property(let property), .property(let get)):
            return [
                make(.property, returns: TypeAnnotation(property.variable.type)) {
                    try get($0["self"] ?? .nothing)
                }
            ]
        case (.property(let property), .settableProperty(let get, let set)):
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
                        (result: .nothing, receiver: try set($0, arguments["newValue"] ?? .nothing))
                    }
                },
            ]
        case (.property(let property), .staticProperty(let get)):
            return [
                make(
                    .property,
                    isStatic: true,
                    returns: TypeAnnotation(property.variable.type)
                ) { _ in try get() }
            ]
        case (.initializer(let function), .initializer(let body)):
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
        default:
            preconditionFailure("\(member.name) is not a member of a type")
        }
    }
}

// MARK: Writing one

/// A Swift value type scripts can hold, compare and call the members of, without the host writing a
/// script-side declaration for it: a `FileSize`, a `URL`. A script sees an ordinary type: its
/// members are checked before the script runs, `==`, `<` and hashing go by the Swift value's own,
/// and a word of text becomes one through `parse`.
///
/// Members are key paths and method references, so each one's types are the compiler's and none is
/// spelled twice; `member(_:)` takes what those cannot say.
///
///     interpreter.register(HostTypeBuilder<URL>()
///         .property("host", \.host)
///         .method("appending", labels: [nil], URL.appendingPathComponent(_:)))
public struct HostTypeBuilder<T: Sendable>: Sendable {
    private(set) var type: HostType

    /// A type for `T`, named `name` in scripts (`T`'s own name by default). What `T` says of
    /// itself is read from it: `Equatable`, `Hashable`, `Comparable`, `Sequence` (with its
    /// `Element`), `Encodable` and `CustomStringConvertible`, a word of text that is one
    /// (`LosslessStringConvertible`), and a string literal that is one
    /// (`ExpressibleByStringLiteral`).
    public init(_ name: String? = nil) {
        let name = name ?? String(describing: T.self)
        self.type = HostType(name: name)
        type.conformances = Self.conformances()
        if let element = Self.sequenceElement() {
            type.associatedTypes["Element"] = element
        }
        type.parse = Self.parser(named: name)
        type.literal = Self.literalMaker(named: name)
    }

    private static func conformances() -> [String] {
        var found: [String] = []
        if T.self is any Equatable.Type { found.append("Equatable") }
        if T.self is any Hashable.Type { found.append("Hashable") }
        if T.self is any Comparable.Type { found.append("Comparable") }
        if T.self is any Sequence.Type { found.append("Sequence") }
        if T.self is any Encodable.Type { found.append("Encodable") }
        if T.self is any CustomStringConvertible.Type {
            found.append("CustomStringConvertible")
        }
        if T.self is any ExpressibleByStringLiteral.Type {
            found.append("ExpressibleByStringLiteral")
        }
        return found
    }

    private static func sequenceElement() -> ScriptType? {
        func element<S: Sequence>(_: S.Type) -> ScriptType {
            (S.Element.self as? any ScriptConvertible.Type)?.scriptType ?? .any
        }
        guard let sequence = T.self as? any Sequence.Type else { return nil }
        return element(sequence)
    }

    private static func parser(named name: String) -> (@Sendable (String) -> Value?)? {
        func parser<L: LosslessStringConvertible>(_: L.Type) -> @Sendable (String) -> Value? {
            { text in L(text).map { box($0 as! T, as: name) } }
        }
        guard let lossless = T.self as? any LosslessStringConvertible.Type else { return nil }
        return parser(lossless)
    }

    private static func literalMaker(named name: String) -> (@Sendable (String) -> Value?)? {
        func maker<L: ExpressibleByStringLiteral>(_: L.Type) -> @Sendable (String) -> Value? {
            { text in
                (text as? L.StringLiteralType).map { box(L(stringLiteral: $0) as! T, as: name) }
            }
        }
        guard let literal = T.self as? any ExpressibleByStringLiteral.Type else { return nil }
        return maker(literal)
    }

    fileprivate static func box(_ value: T, as name: String) -> Value {
        return SwiftValue.make(value, as: name)
    }

    private func adding(_ member: HostSymbol) -> HostTypeBuilder {
        var copy = self
        copy.type.members.append(member)
        return copy
    }

    /// A member written by hand, for what a key path or a method reference cannot say, such as
    /// an `async` method: made with `HostSymbol`'s `.method`, `.property` and the rest. A
    /// function is not a member, and is registered on its own.
    public func member(_ symbol: HostSymbol) -> HostTypeBuilder {
        guard symbol.function == nil else {
            preconditionFailure("\(symbol.name) is a function, not a member of \(type.name)")
        }
        return adding(symbol)
    }

    /// A property that reads a key path: `.property("host", \.host)`.
    public func property<V: ScriptConvertible>(
        _ name: String,
        _ keyPath: any KeyPath<T, V> & Sendable
    ) -> HostTypeBuilder {
        adding(
            .property(name, type: V.scriptType) {
                try $0.unboxing(T.self)[keyPath: keyPath].value
            }
        )
    }

    /// A method, as a reference to it:
    /// `.method("appending", labels: [nil], URL.appendingPathComponent(_:))`.
    public func method<each Argument: ScriptConvertible, Result: ScriptConvertible>(
        _ name: String,
        labels: [String?] = [],
        throwing: Bool = false,
        _ function: @escaping @Sendable (T) -> (repeat each Argument) throws -> Result
    ) -> HostTypeBuilder {
        adding(
            .method(
                name,
                parameters: HostSymbol.parameters(repeat (each Argument).self, labels: labels),
                returns: Result.scriptType,
                isThrowing: throwing
            ) { receiver, arguments in
                var index = 0
                func next() -> Value { defer { index += 1 }; return arguments[index] }
                return try function(receiver.unboxing(T.self))(
                    repeat try (each Argument)(next())
                )
                .value
            }
        )
    }

    /// A function of the type itself: `.static("now", Date.init)`.
    public func `static`<each Argument: ScriptConvertible, Result: ScriptConvertible>(
        _ name: String,
        labels: [String?] = [],
        throwing: Bool = false,
        _ function: @escaping @Sendable (repeat each Argument) throws -> Result
    ) -> HostTypeBuilder {
        adding(
            .staticMethod(
                name,
                parameters: HostSymbol.parameters(repeat (each Argument).self, labels: labels),
                returns: Result.scriptType,
                isThrowing: throwing
            ) { arguments in
                var index = 0
                func next() -> Value { defer { index += 1 }; return arguments[index] }
                return try function(repeat try (each Argument)(next())).value
            }
        )
    }

    /// How a script makes one: `.initializer(labels: ["string"], URL.init(string:))`.
    public func initializer<each Argument: ScriptConvertible>(
        labels: [String?] = [],
        throwing: Bool = false,
        _ make: @escaping @Sendable (repeat each Argument) throws -> T
    ) -> HostTypeBuilder {
        let name = type.name
        return adding(
            .initializer(
                parameters: HostSymbol.parameters(repeat (each Argument).self, labels: labels),
                returns: .named(.host(name)),
                isThrowing: throwing
            ) { arguments in
                var index = 0
                func next() -> Value { defer { index += 1 }; return arguments[index] }
                return Self.box(try make(repeat try (each Argument)(next())), as: name)
            }
        )
    }

    /// An initializer that can fail, which a script sees as one that gives an optional:
    /// `.failableInitializer(URL.init(string:))`.
    public func failableInitializer<each Argument: ScriptConvertible>(
        labels: [String?] = [],
        throwing: Bool = false,
        _ make: @escaping @Sendable (repeat each Argument) throws -> T?
    ) -> HostTypeBuilder {
        let name = type.name
        return adding(
            .initializer(
                parameters: HostSymbol.parameters(repeat (each Argument).self, labels: labels),
                returns: .named(.optional, [.named(.host(name))]),
                isThrowing: throwing
            ) { arguments in
                var index = 0
                func next() -> Value { defer { index += 1 }; return arguments[index] }
                return try make(repeat try (each Argument)(next()))
                    .map { Self.box($0, as: name) } ?? .nothing
            }
        )
    }
}

/// A `Sendable` type becomes one a script can hold and a host function can take and give by
/// saying so: `extension URL: ScriptConvertible {}`. It is held as it is, under its Swift name.
extension ScriptConvertible where Self: Sendable {
    public static var scriptType: ScriptType { .named(.host(Value.hostName(of: Self.self))) }
    public init(_ swiitValue: Value) throws { self = try SwiftValue.unbox(Self.self, swiitValue) }
    public var value: Value { SwiftValue.make(self, as: Value.hostName(of: Self.self)) }
}

/// The Swift collections a script holds as they are, which the bridge gives members to.
extension Set: ScriptConvertible where Element: Hashable {
    public static var scriptType: ScriptType { .named(.set, [.any]) }
    public init(_ swiitValue: Value) throws { self = try SwiftValue.unbox(Self.self, swiitValue) }
    public var value: Value { SwiftValue.make(self, as: "Set") }
}

/// Any sequence a script holds, read one item at a time so a range of a billion is never a list: a
/// list's items, a set's, a range of Ints, a host type's text. A value that isn't one is an error.
/// A script's own iterators, which can throw, are read by the interpreter's `for`.
extension AnySequence: ScriptConvertible where Element == Value {
    public static var scriptType: ScriptType { .named(.sequence, [.any]) }
    public init(_ swiitValue: Value) throws {
        guard let items = Interpreter.items(of: swiitValue) else {
            throw SwiitError("expected a sequence, not \(swiitValue.bridgeTypeName)")
        }
        self.init { items }
    }
    public var value: Value { .list(Array(self)) }
}

extension ArraySlice: ScriptConvertible {
    public static var scriptType: ScriptType { .named(.arraySlice, [.any]) }
    public init(_ swiitValue: Value) throws { self = try SwiftValue.unbox(Self.self, swiitValue) }
    public var value: Value { SwiftValue.make(self, as: "ArraySlice") }
}
