import Foundation

/// A Swift value type scripts can hold, compare and call the members of, without the host writing a script-side declaration for
/// it: a `FileSize`, a `URL`. A script sees an ordinary type: its members are checked before the script runs, `==`, `<` and
/// hashing go by the Swift value's own, and a word of text becomes one through `parse`.
public struct NativeType: Sendable {
    /// What a member is. A `setter` is a property's other half, for `size.unit = …`.
    public enum MemberKind: Sendable { case method, property, initializer, setter }

    /// A member of the type. Its `function` is called with the arguments in declared order; an instance member's first
    /// parameter is named `self` and receives the value, and scripts do not see it.
    public struct Member: Sendable {
        public var kind: MemberKind
        public var isStatic: Bool
        public var isMutating: Bool
        public var function: HostFunction

        public init(_ kind: MemberKind, isStatic: Bool = false, isMutating: Bool = false, _ function: HostFunction) {
            self.kind = kind
            self.isStatic = isStatic
            self.isMutating = isMutating
            self.function = function
        }
    }

    public var name: String
    /// The protocols it conforms to, of those Swiit knows: `Equatable`, `Hashable`, `Comparable`, `Sequence`.
    public var conformances: [String]
    /// What its associated types are: `Element` is `String` for a sequence of text.
    public var associatedTypes: [String: ValueType]
    public var members: [Member]
    /// A value from text, where text gives a word and the type is wanted.
    public var parse: (@Sendable (String) -> Value?)?
    /// A value from a text literal, where a script writes `"…"` and the type is wanted (`let column: DisplayColumn = "name"`).
    public var literal: (@Sendable (String) -> Value?)?

    public init(
        name: String, conformances: [String] = [], associatedTypes: [String: ValueType] = [:], members: [Member] = [],
        parse: (@Sendable (String) -> Value?)? = nil, literal: (@Sendable (String) -> Value?)? = nil
    ) {
        self.name = name
        self.conformances = conformances
        self.associatedTypes = associatedTypes
        self.members = members
        self.parse = parse
        self.literal = literal
    }
}

extension Value {
    /// A Swift value, held as it is, of a type registered as `NativeType` named `typeName`. Scripts compare and hash it as
    /// Swift does when the type is `Equatable`, `Hashable` or `Comparable`.
    public init<T>(boxing value: T, as typeName: String) {
        self = SwiftValue.make(value, as: typeName)
    }

    /// The Swift value this holds, if it holds one of type `T`.
    public func unboxed<T>(_: T.Type = T.self) throws -> T {
        try SwiftValue.unbox(T.self, self)
    }
}

extension Interpreter {
    /// Makes a Swift value type one scripts can use. Registering a type again adds the members it lacks.
    public func register(_ type: NativeType) {
        var bridged = BridgedType(type)
        // A sequence has what a list has, over its items: `sorted`, `map`, `max`, `joined` (`Output`'s lines).
        if type.conformances.contains("Sequence"), let element = type.associatedTypes["Element"] {
            bridged = bridged.adding(itemMembers(of: TypeAnnotation(element), excluding: Set(type.members.map { $0.function.name })))
        }
        Bridge.register([bridged])
        withMainTask { scopes[0].bindings[type.name] = Binding(value: .object(BridgedTypeName(type.name)), mutable: false) }
    }
}

extension Interpreter {
    /// A list's members, which read their receiver without changing it, made members of a sequence: they take its items as the
    /// list they work on.
    func itemMembers(of element: TypeAnnotation, excluding own: Set<String>) -> [BridgedMember] {
        guard let array = Bridge.types["Array"] else { return [] }
        let checker = TypeChecker(interpreter: self)
        let bindings = ["Element": element]
        return array.members.filter { !$0.isStatic && !$0.isMutating && ($0.kind == .method || $0.kind == .property) && !own.contains($0.name) }.map { member in
            let body: FunctionBody
            if case .native(let call) = member.body {
                body = .native { interpreter, arguments in
                    var arguments = arguments
                    if let receiver = arguments["self"], let items = receiver.items { arguments["self"] = .list(Array(items)) }
                    return try call(interpreter, arguments)
                }
            } else {
                body = member.body
            }
            return BridgedMember(
                kind: member.kind, name: member.name, isStatic: false,
                parameters: member.parameters.map { var made = $0; made.type = checker.substitute($0.type, bindings); return made },
                returns: checker.substitute(member.returns, bindings), generics: member.generics, isThrowing: member.isThrowing,
                isRethrowing: member.isRethrowing, isMutating: false, discardableResult: member.discardableResult, summary: member.summary,
                body: body, parameterDocs: member.parameterDocs, effect: member.effect, typedThrows: member.typedThrows)
        }
    }
}

extension BridgedType {
    init(_ type: NativeType) {
        self.init(
            name: type.name, genericParameters: [],
            conformances: Dictionary(uniqueKeysWithValues: type.conformances.map { ($0, [:]) }),
            associatedTypes: type.associatedTypes.mapValues(TypeAnnotation.init),
            parse: type.parse, literal: type.literal, arrayLiteral: nil,
            members: type.members.map(BridgedMember.init)
        )
    }
}

extension BridgedMember {
    init(_ member: NativeType.Member) {
        let function = member.function
        let hasReceiver = !member.isStatic && member.kind != .initializer
        let parameters = function.parameters.filter { !(hasReceiver && $0.name == "self") }.map { parameter in
            Parameter(label: parameter.label, name: parameter.name, type: TypeAnnotation(parameter.type), variadic: parameter.isVariadic,
                      defaultValue: parameter.defaultValue.map(Expr.literal))
        }
        let call = function.call
        let names = parameters.map(\.name)
        self.init(
            kind: {
                switch member.kind {
                case .method: .method
                case .property: .property
                case .initializer: .initializer
                case .setter: .setter
                }
            }(),
            name: member.kind == .initializer ? "init" : function.name, isStatic: member.isStatic || member.kind == .initializer, parameters: parameters,
            returns: function.returns.map(TypeAnnotation.init) ?? .void, generics: [:],
            isThrowing: function.isThrowing, isRethrowing: false, isMutating: member.isMutating,
            discardableResult: false, summary: function.summary ?? "",
            body: .native { _, arguments in
                var named = Dictionary(uniqueKeysWithValues: names.compactMap { name in arguments[name].map { (name, $0) } })
                if hasReceiver, let receiver = arguments["self"] { named["self"] = receiver }
                return try call(named)
            }
        )
        plain = { arguments in
            var named = Dictionary(uniqueKeysWithValues: names.compactMap { name in arguments[name].map { (name, $0) } })
            if hasReceiver, let receiver = arguments["self"] { named["self"] = receiver }
            return try call(named)
        }
    }
}

// MARK: Writing one

extension NativeType {
    /// A type written from the Swift type itself: members are key paths and method references, so each one's types are the
    /// compiler's and none is spelled twice.
    ///
    ///     interpreter.register(NativeType.Builder<URL>()
    ///         .property("host", \.host)
    ///         .method("appending", labels: [nil], URL.appendingPathComponent(_:)))
    public struct Builder<T: Sendable>: Sendable {
        public private(set) var type: NativeType

        public init(
            _ name: String? = nil, conformances: [String] = [], associatedTypes: [String: ValueType] = [:],
            parse: (@Sendable (String) -> T?)? = nil, literal: (@Sendable (String) -> T?)? = nil
        ) {
            let name = name ?? String(describing: T.self)
            self.type = NativeType(name: name, conformances: conformances, associatedTypes: associatedTypes)
            if let parse { type.parse = { text in parse(text).map { Self.box($0, as: name) } } }
            if let literal { type.literal = { text in literal(text).map { Self.box($0, as: name) } } }
        }

        private var name: String { type.name }

        fileprivate static func box(_ value: T, as name: String) -> Value {
            if let object = value as? any HostObject { return Value(object) }
            return Value(boxing: value, as: name)
        }

        private var receiver: HostFunction.Parameter { .init(name: "self", type: .named(name)) }

        private func adding(_ kind: MemberKind, isStatic: Bool = false, _ function: HostFunction) -> Builder {
            var copy = self
            copy.type.members.append(Member(kind, isStatic: isStatic, function))
            return copy
        }

        fileprivate mutating func append(_ member: Member) { type.members.append(member) }

        fileprivate static func parameters<each Argument: ValueConvertible>(_: repeat (each Argument).Type, labels: [String?]) -> [HostFunction.Parameter] {
            var made: [HostFunction.Parameter] = []
            func add<A: ValueConvertible>(_: A.Type) {
                let label = labels.indices.contains(made.count) ? labels[made.count] : nil
                made.append(HostFunction.Parameter(label: label, name: label ?? "argument\(made.count)", type: A.self))
            }
            repeat add((each Argument).self)
            return made
        }

        /// A property that reads a key path: `.property("host", \.host)`.
        public func property<V: ValueConvertible>(_ name: String, _ keyPath: any KeyPath<T, V> & Sendable) -> Builder {
            adding(.property, HostFunction(name: name, summary: nil, parameters: [receiver], returns: V.valueType) { arguments in
                try arguments[0].unboxed(T.self)[keyPath: keyPath].value
            })
        }

        /// A method, as a reference to it: `.method("appending", labels: [nil], URL.appendingPathComponent(_:))`.
        public func method<each Argument: ValueConvertible, Result: ValueConvertible>(
            _ name: String, labels: [String?] = [], throwing: Bool = false,
            _ function: @escaping @Sendable (T) -> (repeat each Argument) throws -> Result
        ) -> Builder {
            adding(.method, HostFunction(
                name: name, parameters: [receiver] + Self.parameters(repeat (each Argument).self, labels: labels),
                returns: Result.valueType, isThrowing: throwing
            ) { arguments in
                var index = 1
                func next() -> Value { defer { index += 1 }; return arguments[index] }
                return try function(arguments[0].unboxed(T.self))(repeat try (each Argument)(next())).value
            })
        }

        /// A function of the type itself: `.static("now", Date.init)`.
        public func `static`<each Argument: ValueConvertible, Result: ValueConvertible>(
            _ name: String, labels: [String?] = [], throwing: Bool = false,
            _ function: @escaping @Sendable (repeat each Argument) throws -> Result
        ) -> Builder {
            adding(.method, isStatic: true, HostFunction(
                name: name, parameters: Self.parameters(repeat (each Argument).self, labels: labels),
                returns: Result.valueType, isThrowing: throwing
            ) { arguments in
                var index = 0
                func next() -> Value { defer { index += 1 }; return arguments[index] }
                return try function(repeat try (each Argument)(next())).value
            })
        }

        /// How a script makes one: `.initializer(labels: ["string"], URL.init(string:))`.
        public func initializer<each Argument: ValueConvertible>(
            labels: [String?] = [], throwing: Bool = false, _ make: @escaping @Sendable (repeat each Argument) throws -> T
        ) -> Builder {
            let name = name
            return adding(.initializer, HostFunction(
                name: "init", parameters: Self.parameters(repeat (each Argument).self, labels: labels),
                returns: .named(name), isThrowing: throwing
            ) { arguments in
                var index = 0
                func next() -> Value { defer { index += 1 }; return arguments[index] }
                return Self.box(try make(repeat try (each Argument)(next())), as: name)
            })
        }
    }
}

extension NativeType.Builder {
    /// An initializer that can fail, which a script sees as one that gives an optional: `.failableInitializer(URL.init(string:))`.
    public func failableInitializer<each Argument: ValueConvertible>(
        labels: [String?] = [], throwing: Bool = false, _ make: @escaping @Sendable (repeat each Argument) throws -> T?
    ) -> NativeType.Builder<T> {
        let name = type.name
        var copy = self
        copy.append(.init(.initializer, HostFunction(
            name: "init", parameters: Self.parameters(repeat (each Argument).self, labels: labels),
            returns: .optional(.named(name)), isThrowing: throwing
        ) { arguments in
            var index = 0
            func next() -> Value { defer { index += 1 }; return arguments[index] }
            return try make(repeat try (each Argument)(next())).map { Self.box($0, as: name) } ?? .null
        }))
        return copy
    }
}

extension Interpreter {
    public func register<T>(_ builder: NativeType.Builder<T>) { register(builder.type) }
}

/// A value type that is `Hashable` and `Sendable` becomes one a script can hold and a host function can take and give by
/// saying so: `extension URL: ValueConvertible {}`. It is held as it is, under its Swift name.
extension ValueConvertible where Self: Hashable & Sendable {
    public static var valueType: ValueType { .named(String(describing: Self.self)) }
    public init(_ swiitValue: Value) throws { self = try swiitValue.unboxed(Self.self) }
    public var value: Value { Value(boxing: self, as: String(describing: Self.self)) }
}
