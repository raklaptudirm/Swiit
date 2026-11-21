import Foundation

/// What a host says of a type it offers scripts: a name and its members, and what its Swift type
/// says of itself. Written with ``Builder`` for a Swift type, or by hand for one a generator
/// describes, and made a type scripts can use by ``Interpreter/register(_:)-(TypeImplementation)``.
public struct TypeImplementation: Sendable {
    /// What is said of the type: its symbol (a name, documentation and attributes; a host type is
    /// held by value under its Swift name, so it is a structure), its generic parameters, the
    /// protocols its Swift type conforms to of those Swiit knows (`Equatable`, `Hashable`,
    /// `Comparable`, `Sequence`) and its associated types. A builder finds the conformances from the
    /// type.
    public var declaration: TypeDeclaration
    public var symbol: Symbol {
        get { declaration.symbol }
        set { declaration.symbol = newValue }
    }
    public var name: String {
        get { declaration.name }
        set { declaration.name = newValue }
    }
    public var genericParameters: [Symbol] {
        get { declaration.genericParameters }
        set { declaration.genericParameters = newValue }
    }
    public var conformances: [String: [Symbol]] {
        get { declaration.conformances }
        set { declaration.conformances = newValue }
    }
    public var members: [SymbolImplementation]
    /// What a value of the type is: one of the core's kinds with storage of its own, or a Swift value
    /// held as it is. The kinds a program declares join these as the type record grows.
    var representation = Representation.held
    /// The members as the checker and the interpreter run them, from `members`, when the type is
    /// registered.
    var lowered: [BridgedMember] = []

    public init(name: String, members: [SymbolImplementation] = []) {
        declaration = TypeDeclaration(name: name)
        self.members = members
    }
}

extension Value {
    /// The name a Swift type is registered under by default: its own, without its generic arguments.
    static func hostName(of type: Any.Type) -> String {
        String(String(describing: type).prefix { $0 != "<" })
    }

    /// A Swift value kept as it is, as a value of the registered host type `type`
    /// (`TypeRef(nativeType: "FileSize")`): what a member written for a Swift type gives back.
    /// It compares, hashes and sorts as the Swift value does, when its type can.
    public init<T>(boxing value: T, as type: TypeRef) {
        self = SwiftValue.make(value, as: type.name)
    }

    /// The Swift value this holds, which must be one of type `T`; else it throws the error a
    /// member's argument of the wrong type does. It takes the value, so a body that is the last to
    /// hold one (`consume`) leaves nothing else holding the Swift value it unwraps.
    public consuming func unboxing<T>(_: T.Type = T.self) throws -> T {
        try SwiftValue.unbox(T.self, self)
    }
}

extension Interpreter {
    /// Makes a Swift value type one scripts can use. Registering a type again adds the members it
    /// lacks. It gives the type's reference, which is `TypeRef(nativeType: name)`: the same promises hold
    /// of it, and of what they leave out.
    @discardableResult
    public func register<T>(_ builder: TypeImplementation.Builder<T>) -> TypeRef {
        register(builder.type)
    }

    /// Makes a Swift enum one scripts can name on its own (`Shade.dark`, `case .dark:`), as
    /// registering a function or a type that takes or gives one does: for an enum that a
    /// host's declarations name (`declare(_:bodies:)`) and nothing registered has yet.
    public func register<E: BridgedValue & CaseIterable & Hashable & Sendable>(_: E.Type) {
        let enumeration = Value.EnumCase.Enumeration.of(E.self)
        withMainTask {
            scopes[1].bindings[enumeration.name] = Binding(
                value: .object(enumeration),
                mutable: false
            )
        }
    }

    @discardableResult
    public func register(_ type: TypeImplementation) -> TypeRef {
        var bridged = type.lowering()
        // A sequence has what a list has, over its items: `sorted`, `map`, `max`, `joined`
        // (`Output`'s lines).
        if type.conformances["Sequence"] != nil, let element = type.associatedTypes["Element"] {
            bridged = bridged.adding(
                itemMembers(
                    of: TypeAnnotation(element),
                    excluding: Set(type.members.map(\.name))
                )
            )
        }
        Bridge.register([bridged])
        withMainTask {
            // The Swift enums its members take or give, as a function's are.
            for enumeration in type.members.flatMap(\.enums) {
                scopes[1].bindings[enumeration.name] = Binding(
                    value: .object(enumeration),
                    mutable: false
                )
            }
            scopes[0].bindings[type.name] = Binding(
                value: .object(BridgedTypeName(type.name)),
                mutable: false
            )
        }
        return .native(type.name)
    }
}

extension Interpreter {
    /// A list's members, which read their receiver without changing it, made members of a sequence:
    /// they take its items as the list they work on.
    func itemMembers(of element: TypeAnnotation, excluding own: Set<String>) -> [BridgedMember] {
        guard let array = Bridge.types["Array"] else { return [] }
        let checker = TypeChecker(interpreter: self)
        let bindings = ["Element": element]
        return array.lowered
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
                        var made = $0
                        made.type = checker.substitute($0.type, bindings)
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

// MARK: Writing one

/// A Swift value type scripts can hold, compare and call the members of, without the host writing a
/// script-side declaration for it: a `FileSize`, a `URL`. A script sees an ordinary type: its
/// members are checked before the script runs, `==`, `<` and hashing go by the Swift value's own,
/// and a word of text becomes one through `parse`.
///
/// Members are key paths and method references, so each one's types are the compiler's and none is
/// spelled twice; `member(_:)` takes what those cannot say.
///
///     interpreter.register(TypeImplementation.Builder<URL>()
///         .property("host", \.host)
///         .method("appending", labels: [nil], URL.appendingPathComponent(_:)))
extension TypeImplementation {
    public struct Builder<T: Sendable>: Sendable {
        private(set) var type: TypeImplementation

        /// A type for `T`, named `name` in scripts (`T`'s own name by default). What `T` says of
        /// itself is read from it: `Equatable`, `Hashable`, `Comparable`, `Sequence` (with its
        /// `Element`), `Encodable` and `CustomStringConvertible`, a word of text that is one
        /// (`LosslessStringConvertible`), and a string literal that is one
        /// (`ExpressibleByStringLiteral`).
        public init(_ name: String? = nil) {
            let name = name ?? String(describing: T.self)
            self.type = TypeImplementation(name: name)
            type.conformances = Dictionary(
                uniqueKeysWithValues: Self.conformances().map { ($0, []) }
            )
            if let element = Self.sequenceElement() {
                type.members.append(.associatedType("Element", binding: element))
            }
            type.members += Self.textInitializers(named: name)
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
                (S.Element.self as? any BridgedValue.Type)?.scriptType ?? .any
            }
            guard let sequence = T.self as? any Sequence.Type else { return nil }
            return element(sequence)
        }

        /// The initializers a type has from the protocols that read it from text: `init?(_ text:)` for a
        /// `LosslessStringConvertible` type, and `init(stringLiteral:)` for an
        /// `ExpressibleByStringLiteral` one, which is how a script's string literal becomes one.
        private static func textInitializers(named name: String) -> [SymbolImplementation] {
            let own = ScriptType.named(TypeRef(nativeType: name))
            func fromText<L: LosslessStringConvertible>(_: L.Type) -> SymbolImplementation {
                .initializer(
                    summary: "The value the text spells, or nil.",
                    signature: Symbol.Function(
                        parameters: [Symbol.Parameter(name: "text", type: .string)],
                        returns: .optional(own)
                    )
                ) { arguments in
                    guard case .string(let text) = arguments[0].storage,
                        let value = L(text) as? T
                    else { return .nothing }
                    return box(value, as: name)
                }
            }
            func fromLiteral<L: ExpressibleByStringLiteral>(_: L.Type) -> SymbolImplementation {
                .initializer(
                    summary: "The value the string literal is.",
                    signature: Symbol.Function(
                        parameters: [
                            Symbol.Parameter(label: "stringLiteral", name: "value", type: .string)
                        ],
                        returns: own
                    )
                ) { arguments in
                    guard case .string(let text) = arguments[0].storage,
                        let literal = text as? L.StringLiteralType,
                        let value = L(stringLiteral: literal) as? T
                    else { return .nothing }
                    return box(value, as: name)
                }
            }
            var found: [SymbolImplementation] = []
            if let lossless = T.self as? any LosslessStringConvertible.Type {
                found.append(fromText(lossless))
            }
            if let literal = T.self as? any ExpressibleByStringLiteral.Type {
                found.append(fromLiteral(literal))
            }
            return found
        }

        fileprivate static func box(_ value: T, as name: String) -> Value {
            return SwiftValue.make(value, as: name)
        }

        /// It, with `member`, which takes or gives the Swift enums `enums`: registering the type
        /// declares them, as registering a function does.
        private func adding(
            _ member: SymbolImplementation,
            enums: [Value.EnumCase.Enumeration] = []
        ) -> Builder {
            var copy = self
            var member = member
            member.enums += enums
            copy.type.members.append(member)
            return copy
        }

        /// A member written by hand, for what a key path or a method reference cannot say, such as
        /// an `async` method: made with `SymbolImplementation`'s `.method`, `.property` and the rest. A
        /// function is not a member, and is registered on its own.
        public func member(_ symbol: SymbolImplementation) -> Builder {
            guard symbol.function == nil else {
                preconditionFailure("\(symbol.name) is a function, not a member of \(type.name)")
            }
            return adding(symbol)
        }

        /// A property that reads a key path: `.property("host", \.host)`.
        public func property<V: BridgedValue>(
            _ name: String,
            _ keyPath: any KeyPath<T, V> & Sendable
        ) -> Builder {
            adding(
                .property(name, type: V.scriptType) {
                    try $0.unboxing(T.self)[keyPath: keyPath].value
                },
                enums: V.swiitEnums
            )
        }

        /// A method, as a reference to it:
        /// `.method("appending", labels: [nil], URL.appendingPathComponent(_:))`.
        public func method<each Argument: BridgedValue, Result: BridgedValue>(
            _ name: String,
            labels: [String?] = [],
            throwing: Bool = false,
            _ function: @escaping @Sendable (T) -> (repeat each Argument) throws -> Result
        ) -> Builder {
            adding(
                .method(
                    name,
                    parameters: SymbolImplementation.parameters(
                        repeat (each Argument).self,
                        labels: labels
                    ),
                    returns: Result.scriptType,
                    isThrowing: throwing
                ) { receiver, arguments in
                    var index = 0
                    func next() -> Value { defer { index += 1 }; return arguments[index] }
                    return try function(receiver.unboxing(T.self))(
                        repeat try (each Argument)(next())
                    )
                    .value
                },
                enums: SymbolImplementation.enums(repeat (each Argument).self) + Result.swiitEnums
            )
        }

        /// A function of the type itself: `.static("now", Date.init)`.
        public func `static`<each Argument: BridgedValue, Result: BridgedValue>(
            _ name: String,
            labels: [String?] = [],
            throwing: Bool = false,
            _ function: @escaping @Sendable (repeat each Argument) throws -> Result
        ) -> Builder {
            adding(
                .staticMethod(
                    name,
                    parameters: SymbolImplementation.parameters(
                        repeat (each Argument).self,
                        labels: labels
                    ),
                    returns: Result.scriptType,
                    isThrowing: throwing
                ) { arguments in
                    var index = 0
                    func next() -> Value { defer { index += 1 }; return arguments[index] }
                    return try function(repeat try (each Argument)(next())).value
                },
                enums: SymbolImplementation.enums(repeat (each Argument).self) + Result.swiitEnums
            )
        }

        /// How a script makes one: `.initializer(labels: ["string"], URL.init(string:))`.
        public func initializer<each Argument: BridgedValue>(
            labels: [String?] = [],
            throwing: Bool = false,
            _ make: @escaping @Sendable (repeat each Argument) throws -> T
        ) -> Builder {
            let name = type.name
            return adding(
                .initializer(
                    parameters: SymbolImplementation.parameters(
                        repeat (each Argument).self,
                        labels: labels
                    ),
                    returns: .named(.native(name)),
                    isThrowing: throwing
                ) { arguments in
                    var index = 0
                    func next() -> Value { defer { index += 1 }; return arguments[index] }
                    return Self.box(try make(repeat try (each Argument)(next())), as: name)
                },
                enums: SymbolImplementation.enums(repeat (each Argument).self)
            )
        }

        /// An initializer that can fail, which a script sees as one that gives an optional:
        /// `.failableInitializer(URL.init(string:))`.
        public func failableInitializer<each Argument: BridgedValue>(
            labels: [String?] = [],
            throwing: Bool = false,
            _ make: @escaping @Sendable (repeat each Argument) throws -> T?
        ) -> Builder {
            let name = type.name
            return adding(
                .initializer(
                    parameters: SymbolImplementation.parameters(
                        repeat (each Argument).self,
                        labels: labels
                    ),
                    returns: .named(.optional, [.named(.native(name))]),
                    isThrowing: throwing
                ) { arguments in
                    var index = 0
                    func next() -> Value { defer { index += 1 }; return arguments[index] }
                    return try make(repeat try (each Argument)(next()))
                        .map { Self.box($0, as: name) } ?? .nothing
                },
                enums: SymbolImplementation.enums(repeat (each Argument).self)
            )
        }
    }
}

/// A `Sendable` type becomes one a script can hold and a host function can take and give by
/// saying so: `extension URL: BridgedValue {}`. It is held as it is, under its Swift name.
extension BridgedValue where Self: Sendable {
    public init(_ swiitValue: Value) throws { self = try SwiftValue.unbox(Self.self, swiitValue) }
    public var value: Value { SwiftValue.make(self, as: Value.hostName(of: Self.self)) }
    public static var scriptType: ScriptType { .named(.native(typeImplementation.name)) }
}

/// The Swift collections a script holds as they are, which the bridge gives members to.
extension Set: BridgedValue where Element: Hashable {
    public static var scriptType: ScriptType { .named(.set, [.any]) }
    public init(_ swiitValue: Value) throws { self = try SwiftValue.unbox(Self.self, swiitValue) }
    public var value: Value { SwiftValue.make(self, as: "Set") }
}

/// Any sequence a script holds, read one item at a time so a range of a billion is never a list: a
/// list's items, a set's, a range of Ints, a host type's text. A value that isn't one is an error.
/// A script's own iterators, which can throw, are read by the interpreter's `for`.
extension AnySequence: BridgedValue where Element == Value {
    public static var scriptType: ScriptType { .named(.sequence, [.any]) }
    public init(_ swiitValue: Value) throws {
        guard let items = Interpreter.items(of: swiitValue) else {
            throw SwiitError("expected a sequence, not \(swiitValue.bridgeTypeName)")
        }
        self.init { items }
    }
    public var value: Value { .list(Array(self)) }
}

extension ArraySlice: BridgedValue {
    public static var scriptType: ScriptType { .named(.arraySlice, [.any]) }
    public init(_ swiitValue: Value) throws { self = try SwiftValue.unbox(Self.self, swiitValue) }
    public var value: Value { SwiftValue.make(self, as: "ArraySlice") }
}
