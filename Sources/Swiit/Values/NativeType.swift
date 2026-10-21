import Foundation

/// A Swift value type scripts can hold, compare and call the members of, without the host writing a
/// script-side declaration for it: a `FileSize`, a `URL`. A script sees an ordinary type: its
/// members are checked before the script runs, `==`, `<` and hashing go by the Swift value's own,
/// and a word of text becomes one through `parse`.
public struct NativeType: Sendable {
    /// A member of the type. Scripts see its name and signature, which the checker reads, so a use
    /// of it is checked before it runs; what each kind carries is what that kind has.
    public struct Member: Sendable {
        public var name: String
        /// The line `help` shows.
        public var summary: String
        public var kind: Kind

        public init(_ name: String, summary: String = "", _ kind: Kind) {
            self.name = name
            self.summary = summary
            self.kind = kind
        }

        /// What a member is. A body is called with its arguments in declared order, defaults filled
        /// in; an instance member's also with the receiver, which scripts do not see as a parameter.
        public enum Kind: Sendable {
            case method(
                Symbol.Function,
                body: @Sendable (_ receiver: Value, _ arguments: [Value]) throws -> Value
            )
            /// A method that changes its receiver, like `append`: it gives its result and the
            /// receiver as it is now.
            case mutatingMethod(
                Symbol.Function,
                body:
                    @Sendable (_ receiver: Value, _ arguments: [Value]) throws
                    -> (result: Value, receiver: Value)
            )
            case staticMethod(
                Symbol.Function,
                body: @Sendable (_ arguments: [Value]) throws -> Value
            )
            case property(ValueType, Access)
            case staticProperty(ValueType, get: @Sendable () throws -> Value)
            case initializer(
                Symbol.Function,
                body: @Sendable (_ arguments: [Value]) throws -> Value
            )
            /// An initializer that can fail, which a script sees as one that gives an optional:
            /// the body gives nothing for a failure.
            case failableInitializer(
                Symbol.Function,
                body: @Sendable (_ arguments: [Value]) throws -> Value
            )
        }

        /// What a script can do with a property.
        public enum Access: Sendable {
            case readOnly(get: @Sendable (_ receiver: Value) throws -> Value)
            /// A setter gives the receiver as it is now, which is how a value type changes.
            case readWrite(
                get: @Sendable (_ receiver: Value) throws -> Value,
                set: @Sendable (_ receiver: Value, _ newValue: Value) throws -> Value
            )
        }
    }

    public var name: String
    public var members: [Member]
    /// The protocols its Swift type conforms to, of those Swiit knows: `Equatable`, `Hashable`,
    /// `Comparable`, `Sequence`. A builder finds them from the type.
    var conformances: [String] = []
    /// What its associated types are: `Element` is `String` for a sequence of text.
    var associatedTypes: [String: ValueType] = [:]
    /// A value from text, where text gives a word and the type is wanted.
    var parse: (@Sendable (String) -> Value?)?
    /// A value from a text literal, where a script writes `"…"` and the type is wanted
    /// (`let column: DisplayColumn = "name"`).
    var literal: (@Sendable (String) -> Value?)?

    /// A type described by hand, from its members alone. `NativeType.Builder` also finds what the
    /// Swift type says of itself: its conformances, how text becomes one.
    public init(name: String, members: [Member] = []) {
        self.name = name
        self.members = members
    }
}

extension Value {
    /// A Swift value, held as it is, of a type registered as `NativeType` named `typeName`. Scripts
    /// compare and hash it as Swift does when the type is `Equatable`, `Hashable` or `Comparable`.
    public init<T>(boxing value: T, as typeName: String) {
        self = SwiftValue.make(value, as: typeName)
    }

    /// The Swift value this holds, if it holds one of type `T`.
    public func unboxed<T>(_: T.Type = T.self) throws -> T {
        try SwiftValue.unbox(T.self, self)
    }
}

extension Interpreter {
    /// Makes a Swift value type one scripts can use. Registering a type again adds the members it
    /// lacks.
    public func register(_ type: NativeType) {
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
                        if let receiver = arguments["self"], let items = receiver.items {
                            arguments["self"] = .list(Array(items))
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
                    discardableResult: member.discardableResult,
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
    init(_ type: NativeType) {
        self.init(
            name: type.name,
            genericParameters: [],
            conformances: Dictionary(uniqueKeysWithValues: type.conformances.map { ($0, [:]) }),
            associatedTypes: type.associatedTypes.mapValues(TypeAnnotation.init),
            parse: type.parse,
            literal: type.literal,
            arrayLiteral: nil,
            members: type.members.flatMap { BridgedMember.members(of: $0, in: type.name) }
        )
    }
}

extension BridgedMember {
    /// What a script can call, from what a host wrote: a read-write property is a property and its
    /// setter.
    static func members(of member: NativeType.Member, in typeName: String) -> [BridgedMember] {
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
                generics: function?.generics ?? [:],
                isThrowing: function?.isThrowing ?? false,
                isRethrowing: false,
                isMutating: isMutating,
                discardableResult: false,
                summary: member.summary,
                body: .native { _, arguments in try call(arguments) },
                effect: function?.isAsync == true ? .async : .sync
            )
            made.plain = call
            return made
        }
        switch member.kind {
        case .method(let function, let body):
            let order = ordered(function)
            return [
                make(
                    .method,
                    parameters: parameters(function),
                    returns: TypeAnnotation(function.returns),
                    function: function
                ) { try body($0["self"] ?? .nothing, order($0)) }
            ]
        case .mutatingMethod(let function, let body):
            let order = ordered(function)
            return [
                make(
                    .method,
                    parameters: parameters(function),
                    returns: TypeAnnotation(function.returns),
                    function: function,
                    isMutating: true
                ) {
                    let (result, receiver) = try body($0["self"] ?? .nothing, order($0))
                    return .list([result, receiver])
                }
            ]
        case .staticMethod(let function, let body):
            let order = ordered(function)
            return [
                make(
                    .method,
                    isStatic: true,
                    parameters: parameters(function),
                    returns: TypeAnnotation(function.returns),
                    function: function
                ) { try body(order($0)) }
            ]
        case .property(let type, .readOnly(let get)):
            return [
                make(.property, returns: TypeAnnotation(type)) { try get($0["self"] ?? .nothing) }
            ]
        case .property(let type, .readWrite(let get, let set)):
            return [
                make(.property, returns: TypeAnnotation(type)) { try get($0["self"] ?? .nothing) },
                make(
                    .setter,
                    parameters: [
                        Parameter(label: nil, name: "newValue", type: TypeAnnotation(type))
                    ],
                    returns: .void,
                    isMutating: true
                ) {
                    .list([.nothing, try set($0["self"] ?? .nothing, $0["newValue"] ?? .nothing)])
                },
            ]
        case .staticProperty(let type, let get):
            return [
                make(.property, isStatic: true, returns: TypeAnnotation(type)) { _ in try get() }
            ]
        case .initializer(let function, let body):
            let order = ordered(function)
            return [
                make(
                    .initializer,
                    isStatic: true,
                    name: "init",
                    parameters: parameters(function),
                    returns: .named(typeName),
                    function: function
                ) { try body(order($0)) }
            ]
        case .failableInitializer(let function, let body):
            let order = ordered(function)
            return [
                make(
                    .initializer,
                    isStatic: true,
                    name: "init",
                    parameters: parameters(function),
                    returns: .optional(.named(typeName)),
                    function: function
                ) { try body(order($0)) }
            ]
        }
    }
}

// MARK: Writing one

extension NativeType {
    /// A type written from the Swift type itself: members are key paths and method references, so
    /// each one's types are the compiler's and none is spelled twice.
    ///
    ///     interpreter.register(NativeType.Builder<URL>()
    ///         .property("host", \.host)
    ///         .method("appending", labels: [nil], URL.appendingPathComponent(_:)))
    public struct Builder<T: Sendable>: Sendable {
        public private(set) var type: NativeType

        /// A type for `T`, named `name` in scripts (`T`'s own name by default). What `T` says of
        /// itself is read from it: `Equatable`, `Hashable`, `Comparable`, `Sequence` (with its
        /// `Element`), `Encodable` and `CustomStringConvertible`, a word of text that is one
        /// (`LosslessStringConvertible`), and a string literal that is one
        /// (`ExpressibleByStringLiteral`).
        public init(_ name: String? = nil) {
            let name = name ?? String(describing: T.self)
            self.type = NativeType(name: name)
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
            if T.self is any StandsForText.Type { found.append("StandsForText") }
            if T.self is any ExpressibleByStringLiteral.Type {
                found.append("ExpressibleByStringLiteral")
            }
            return found
        }

        private static func sequenceElement() -> ValueType? {
            func element<S: Sequence>(_: S.Type) -> ValueType {
                (S.Element.self as? any ValueConvertible.Type)?.valueType ?? .any
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
            if let object = value as? any HostObject { return Value(object) }
            return Value(boxing: value, as: name)
        }

        private func adding(_ member: Member) -> Builder {
            var copy = self
            copy.type.members.append(member)
            return copy
        }

        fileprivate static func parameters<each Argument: ValueConvertible>(
            _: repeat (each Argument).Type,
            labels: [String?]
        ) -> [Symbol.Parameter] {
            var made: [Symbol.Parameter] = []
            func add<A: ValueConvertible>(_: A.Type) {
                let label = labels.indices.contains(made.count) ? labels[made.count] : nil
                made.append(
                    Symbol.Parameter(
                        label: label,
                        name: label ?? "argument\(made.count)",
                        type: A.self
                    )
                )
            }
            repeat add((each Argument).self)
            return made
        }

        /// A property that reads a key path: `.property("host", \.host)`.
        public func property<V: ValueConvertible>(
            _ name: String,
            _ keyPath: any KeyPath<T, V> & Sendable
        ) -> Builder {
            adding(
                Member(
                    name,
                    .property(
                        V.valueType,
                        .readOnly { try $0.unboxed(T.self)[keyPath: keyPath].value }
                    )
                )
            )
        }

        /// A method, as a reference to it:
        /// `.method("appending", labels: [nil], URL.appendingPathComponent(_:))`.
        public func method<each Argument: ValueConvertible, Result: ValueConvertible>(
            _ name: String,
            labels: [String?] = [],
            throwing: Bool = false,
            _ function: @escaping @Sendable (T) -> (repeat each Argument) throws -> Result
        ) -> Builder {
            adding(
                Member(
                    name,
                    .method(
                        Symbol.Function(
                            parameters: Self.parameters(
                                repeat (each Argument).self,
                                labels: labels
                            ),
                            returns: Result.valueType,
                            isThrowing: throwing
                        )
                    ) { receiver, arguments in
                        var index = 0
                        func next() -> Value { defer { index += 1 }; return arguments[index] }
                        return try function(receiver.unboxed(T.self))(
                            repeat try (each Argument)(next())
                        )
                        .value
                    }
                )
            )
        }

        /// A function of the type itself: `.static("now", Date.init)`.
        public func `static`<each Argument: ValueConvertible, Result: ValueConvertible>(
            _ name: String,
            labels: [String?] = [],
            throwing: Bool = false,
            _ function: @escaping @Sendable (repeat each Argument) throws -> Result
        ) -> Builder {
            adding(
                Member(
                    name,
                    .staticMethod(
                        Symbol.Function(
                            parameters: Self.parameters(
                                repeat (each Argument).self,
                                labels: labels
                            ),
                            returns: Result.valueType,
                            isThrowing: throwing
                        )
                    ) { arguments in
                        var index = 0
                        func next() -> Value { defer { index += 1 }; return arguments[index] }
                        return try function(repeat try (each Argument)(next())).value
                    }
                )
            )
        }

        /// How a script makes one: `.initializer(labels: ["string"], URL.init(string:))`.
        public func initializer<each Argument: ValueConvertible>(
            labels: [String?] = [],
            throwing: Bool = false,
            _ make: @escaping @Sendable (repeat each Argument) throws -> T
        ) -> Builder {
            let name = type.name
            return adding(
                Member(
                    "init",
                    .initializer(
                        Symbol.Function(
                            parameters: Self.parameters(
                                repeat (each Argument).self,
                                labels: labels
                            ),
                            returns: .named(name),
                            isThrowing: throwing
                        )
                    ) { arguments in
                        var index = 0
                        func next() -> Value { defer { index += 1 }; return arguments[index] }
                        return Self.box(try make(repeat try (each Argument)(next())), as: name)
                    }
                )
            )
        }

        /// An initializer that can fail, which a script sees as one that gives an optional:
        /// `.failableInitializer(URL.init(string:))`.
        public func failableInitializer<each Argument: ValueConvertible>(
            labels: [String?] = [],
            throwing: Bool = false,
            _ make: @escaping @Sendable (repeat each Argument) throws -> T?
        ) -> Builder {
            let name = type.name
            return adding(
                Member(
                    "init",
                    .failableInitializer(
                        Symbol.Function(
                            parameters: Self.parameters(
                                repeat (each Argument).self,
                                labels: labels
                            ),
                            returns: .optional(.named(name)),
                            isThrowing: throwing
                        )
                    ) { arguments in
                        var index = 0
                        func next() -> Value { defer { index += 1 }; return arguments[index] }
                        return try make(repeat try (each Argument)(next()))
                            .map { Self.box($0, as: name) } ?? .null
                    }
                )
            )
        }
    }
}

extension Interpreter {
    public func register<T>(_ builder: NativeType.Builder<T>) { register(builder.type) }
}

/// A value type that is `Hashable` and `Sendable` becomes one a script can hold and a host function
/// can take and give by saying so: `extension URL: ValueConvertible {}`. It is held as it is, under
/// its Swift name.
extension ValueConvertible where Self: Hashable & Sendable {
    public static var valueType: ValueType { .named(String(describing: Self.self)) }
    public init(_ swiitValue: Value) throws { self = try swiitValue.unboxed(Self.self) }
    public var value: Value { Value(boxing: self, as: String(describing: Self.self)) }
}
