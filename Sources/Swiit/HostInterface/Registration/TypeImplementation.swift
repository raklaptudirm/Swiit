import Foundation

/// What a host says of a type it offers scripts: a name and its members, and what its Swift type
/// says of itself. Written with ``BridgedType`` for a Swift type, or by hand for one a generator
/// describes, and made a type scripts can use by ``Interpreter/register(_:)-(TypeImplementation)``.
public struct TypeImplementation: Sendable {
    /// What a script sees of the type: a symbol of kind `.type` (a name, documentation and attributes,
    /// and its kind, reference, generic parameters and the protocols its Swift type conforms to of
    /// those Swiit knows: `Equatable`, `Hashable`, `Comparable`, `Sequence`). A host type is held by
    /// value under its Swift name, so it is a structure. A builder finds the conformances from the
    /// type.
    public var symbol: Symbol
    public var name: String {
        get { symbol.name }
        set {
            symbol.name = newValue
            symbol.nominal?.typeRef = .native(newValue)
        }
    }
    public var genericParameters: [Symbol] {
        get { symbol.nominal?.genericParameters ?? [] }
        set { symbol.nominal?.genericParameters = newValue }
    }
    public var conformances: [String: [Symbol]] {
        get { symbol.nominal?.conformances ?? [:] }
        set { symbol.nominal?.conformances = newValue }
    }
    public var members: [SymbolImplementation]
    /// What a value of the type is: one of the core's kinds with storage of its own, or a Swift value
    /// held as it is. The kinds a program declares join these as the type record grows.
    var representation = Representation.held
    /// The members as the checker and the interpreter run them, from `members`, when the type is
    /// registered.
    var lowered: [BridgedMember] = []

    public init(name: String, members: [SymbolImplementation] = []) {
        symbol = Symbol(
            name: name,
            kind: .type(Symbol.Nominal(kind: .structure, typeRef: .native(name)))
        )
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
    public func register<T>(_ builder: BridgedType<T>) -> TypeRef {
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
                value: .object(NativeTypeName(type.name)),
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

/// A `Sendable` type becomes one a script can hold and a host function can take and give by
/// saying so: `extension URL: BridgedValue {}`. It is held as it is, under its Swift name.
extension BridgedValue where Self: Sendable {
    public init(_ swiitValue: Value) throws { self = try SwiftValue.unbox(Self.self, swiitValue) }
    public var value: Value { SwiftValue.make(self, as: Value.hostName(of: Self.self)) }
    public static var typeExpression: TypeExpression { .named(.native(typeImplementation.name)) }
}

/// The Swift collections a script holds as they are, which the bridge gives members to.
extension Set: BridgedValue where Element: Hashable {
    public static var typeExpression: TypeExpression { .named(.set, [.any]) }
    public init(_ swiitValue: Value) throws { self = try SwiftValue.unbox(Self.self, swiitValue) }
    public var value: Value { SwiftValue.make(self, as: "Set") }
}

/// Any sequence a script holds, read one item at a time so a range of a billion is never a list: a
/// list's items, a set's, a range of Ints, a host type's text. A value that isn't one is an error.
/// A script's own iterators, which can throw, are read by the interpreter's `for`.
extension AnySequence: BridgedValue where Element == Value {
    public static var typeExpression: TypeExpression { .named(.sequence, [.any]) }
    public init(_ swiitValue: Value) throws {
        guard let items = Interpreter.items(of: swiitValue) else {
            throw SwiitError("expected a sequence, not \(swiitValue.bridgeTypeName)")
        }
        self.init { items }
    }
    public var value: Value { .list(Array(self)) }
}

extension ArraySlice: BridgedValue {
    public static var typeExpression: TypeExpression { .named(.arraySlice, [.any]) }
    public init(_ swiitValue: Value) throws { self = try SwiftValue.unbox(Self.self, swiitValue) }
    public var value: Value { SwiftValue.make(self, as: "ArraySlice") }
}
