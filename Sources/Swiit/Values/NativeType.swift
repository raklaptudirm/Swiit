import Foundation

/// A Swift value type scripts can hold, compare and call the members of, without the host writing a script-side declaration for
/// it: a `FileSize`, a `URL`. A script sees an ordinary type: its members are checked before the script runs, `==`, `<` and
/// hashing go by the Swift value's own, and a word on a command line becomes one through `parse`.
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
    /// A value from text, where a script or a command line gives text and the type is wanted.
    public var parse: (@Sendable (String) -> Value?)?

    public init(
        name: String, conformances: [String] = [], associatedTypes: [String: ValueType] = [:], members: [Member] = [],
        parse: (@Sendable (String) -> Value?)? = nil
    ) {
        self.name = name
        self.conformances = conformances
        self.associatedTypes = associatedTypes
        self.members = members
        self.parse = parse
    }
}

extension Value {
    /// A Swift value, held as it is, of a type registered as `NativeType` named `typeName`. Scripts compare and hash it as
    /// Swift does when the type is `Equatable`, `Hashable` or `Comparable`.
    public init<T: Sendable>(boxing value: T, as typeName: String) {
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
        Bridge.register([BridgedType(type)])
        withMainTask { scopes[0].bindings[type.name] = Binding(value: .object(BridgedTypeName(type.name)), mutable: false) }
    }
}

extension BridgedType {
    init(_ type: NativeType) {
        self.init(
            name: type.name, genericParameters: [],
            conformances: Dictionary(uniqueKeysWithValues: type.conformances.map { ($0, [:]) }),
            associatedTypes: type.associatedTypes.mapValues(TypeAnnotation.init),
            parse: type.parse, literal: nil, arrayLiteral: nil,
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
    }
}
