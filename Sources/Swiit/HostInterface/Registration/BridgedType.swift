import Foundation

/// A Swift value type scripts can hold, compare and call the members of, without the host writing a
/// script-side declaration for it: a `FileSize`, a `URL`. A script sees an ordinary type: its
/// members are checked before the script runs, `==`, `<` and hashing go by the Swift value's own,
/// and a word of text becomes one through `parse`.
///
/// Members are key paths and method references, so each one's types are the compiler's and none is
/// spelled twice; `member(_:)` takes what those cannot say.
///
///     interpreter.register(BridgedType<URL>()
///         .property("host", \.host)
///         .method("appending", labels: [nil], URL.appendingPathComponent(_:)))
public struct BridgedType<T: Sendable>: Sendable {
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

    private static func sequenceElement() -> TypeExpression? {
        func element<S: Sequence>(_: S.Type) -> TypeExpression {
            (S.Element.self as? any BridgedValue.Type)?.typeExpression ?? .any
        }
        guard let sequence = T.self as? any Sequence.Type else { return nil }
        return element(sequence)
    }

    /// The initializers a type has from the protocols that read it from text: `init?(_ text:)` for a
    /// `LosslessStringConvertible` type, and `init(stringLiteral:)` for an
    /// `ExpressibleByStringLiteral` one, which is how a script's string literal becomes one.
    private static func textInitializers(named name: String) -> [SymbolImplementation] {
        let own = TypeExpression.named(TypeRef(nativeType: name))
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
    ) -> BridgedType {
        var copy = self
        var member = member
        member.enums += enums
        copy.type.members.append(member)
        return copy
    }

    /// A member written by hand, for what a key path or a method reference cannot say, such as
    /// an `async` method: made with `SymbolImplementation`'s `.method`, `.property` and the rest. A
    /// function is not a member, and is registered on its own.
    public func member(_ symbol: SymbolImplementation) -> BridgedType {
        guard symbol.function == nil else {
            preconditionFailure("\(symbol.name) is a function, not a member of \(type.name)")
        }
        return adding(symbol)
    }

    /// A property that reads a key path: `.property("host", \.host)`.
    public func property<V: BridgedValue>(
        _ name: String,
        _ keyPath: any KeyPath<T, V> & Sendable
    ) -> BridgedType {
        adding(
            .property(name, type: V.typeExpression) {
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
    ) -> BridgedType {
        adding(
            .method(
                name,
                parameters: SymbolImplementation.parameters(
                    repeat (each Argument).self,
                    labels: labels
                ),
                returns: Result.typeExpression,
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
    ) -> BridgedType {
        adding(
            .staticMethod(
                name,
                parameters: SymbolImplementation.parameters(
                    repeat (each Argument).self,
                    labels: labels
                ),
                returns: Result.typeExpression,
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
    ) -> BridgedType {
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
    ) -> BridgedType {
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
