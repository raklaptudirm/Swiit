import Foundation

/// What a host offers a script: a function, or a member of a type (`HostType`). It is what a script
/// sees, as a `Symbol` (its name, summary, signature and attributes, which `symbols(named:)` says
/// of it as they are), and the Swift that runs when it is used.
///
/// The two always agree: the only ways to make one are the functions here, and each makes the
/// `Symbol.Kind` and the body that fit each other, so a static method cannot be given a receiver nor
/// a settable property no setter.
public struct HostSymbol: Sendable {
    /// What a script sees.
    public let symbol: Symbol
    let body: Body

    /// What runs. A body is called with its arguments in declared order, defaults filled in; an
    /// instance member's also with the receiver, which scripts do not see as a parameter.
    enum Body: Sendable {
        /// A function that takes what a call bound by parameter name.
        case function(@Sendable ([String: Value]) throws -> Value)
        case method(@Sendable (_ receiver: Value, _ arguments: [Value]) throws -> Value)
        /// A method that changes its receiver, like `append`: it gives its result and the receiver
        /// as it is now.
        case mutatingMethod(
            @Sendable (_ receiver: Value, _ arguments: [Value]) throws
                -> (result: Value, receiver: Value)
        )
        case staticMethod(@Sendable (_ arguments: [Value]) throws -> Value)
        case property(get: @Sendable (_ receiver: Value) throws -> Value)
        /// A setter gives the receiver as it is now, which is how a value type changes.
        case settableProperty(
            get: @Sendable (_ receiver: Value) throws -> Value,
            set: @Sendable (_ receiver: Value, _ newValue: Value) throws -> Value
        )
        case staticProperty(get: @Sendable () throws -> Value)
        /// What makes a value of the type; for an initializer that can fail, nothing is a failure.
        case initializer(@Sendable (_ arguments: [Value]) throws -> Value)
    }

    init(
        name: String,
        summary: String = "",
        kind: Symbol.Kind,
        attributes: [Symbol.Attribute] = [],
        body: Body
    ) {
        var symbol = Symbol(
            name: name,
            summary: summary.isEmpty ? nil : summary,
            kind: kind,
            attributes: attributes
        )
        symbol.isBuiltin = true
        self.symbol = symbol
        self.body = body
    }

    var name: String { symbol.name }
    var summary: String { symbol.summary ?? "" }

    /// What a function is, for one made as a function; nil for a member.
    var function: (signature: Symbol.Function, call: @Sendable ([String: Value]) throws -> Value)? {
        guard case .function(let signature) = symbol.kind, case .function(let call) = body else {
            return nil
        }
        return (signature, call)
    }
}

// MARK: Functions

extension HostSymbol {
    /// A function whose shape may be known only at run time: it is checked like any function the
    /// script declares. `body` is called with its arguments in declared order, defaults filled in.
    public static func function(
        name: String,
        summary: String = "",
        parameters: [Symbol.Parameter] = [],
        returns: ScriptType = .void,
        isThrowing: Bool = false,
        generics: [Symbol.GenericParameter] = [],
        attributes: [Symbol.Attribute] = [],
        body: @escaping @Sendable ([Value]) throws -> Value
    ) -> HostSymbol {
        let defaults = parameters.map { parameter -> (String, Value?) in
            if case .defaulted(.value(let value)) = parameter.arity {
                return (parameter.name, value)
            }
            return (parameter.name, nil)
        }
        return function(
            name: name,
            summary: summary,
            signature: Symbol.Function(
                parameters: parameters,
                returns: returns,
                isThrowing: isThrowing,
                generics: generics
            ),
            attributes: attributes
        ) { arguments in try body(defaults.map { arguments[$0.0] ?? $0.1 ?? .nothing }) }
    }

    /// A function whose result is a Swift type:
    /// `HostSymbol.function(name: "size", returns: Int.self) { _ in 3 }`.
    public static func function<T: ScriptConvertible>(
        name: String,
        summary: String = "",
        parameters: [Symbol.Parameter] = [],
        returns: T.Type,
        isThrowing: Bool = false,
        generics: [Symbol.GenericParameter] = [],
        attributes: [Symbol.Attribute] = [],
        body: @escaping @Sendable ([Value]) throws -> Value
    ) -> HostSymbol {
        function(
            name: name,
            summary: summary,
            parameters: parameters,
            returns: ScriptType(returns),
            isThrowing: isThrowing,
            generics: generics,
            attributes: attributes,
            body: body
        )
    }

    /// As the host's functions are described: a body taking the arguments by name.
    static func function(
        name: String,
        summary: String = "",
        signature: Symbol.Function,
        attributes: [Symbol.Attribute] = [],
        call: @escaping @Sendable ([String: Value]) throws -> Value
    ) -> HostSymbol {
        HostSymbol(
            name: name,
            summary: summary,
            kind: .function(signature),
            attributes: attributes,
            body: .function(call)
        )
    }

    /// As the language's own builtins are described: a body taking the arguments by name.
    static func function(
        name: String,
        summary: String = "",
        parameters: [Symbol.Parameter],
        returnType: ScriptType?,
        isThrowing: Bool = false,
        call: @escaping @Sendable ([String: Value]) throws -> Value
    ) -> HostSymbol {
        function(
            name: name,
            summary: summary,
            signature: Symbol.Function(
                parameters: parameters,
                returns: returnType ?? .void,
                isThrowing: isThrowing
            ),
            call: call
        )
    }
}

// MARK: Members

extension HostSymbol {
    private static func signature(
        _ parameters: [Symbol.Parameter],
        _ returns: ScriptType,
        _ isThrowing: Bool,
        _ isAsync: Bool = false,
        _ generics: [Symbol.GenericParameter] = []
    ) -> Symbol.Function {
        Symbol.Function(
            parameters: parameters,
            returns: returns,
            isThrowing: isThrowing,
            isAsync: isAsync,
            generics: generics
        )
    }

    /// A method of a type, which reads its receiver.
    public static func method(
        _ name: String,
        summary: String = "",
        parameters: [Symbol.Parameter] = [],
        returns: ScriptType = .void,
        isThrowing: Bool = false,
        isAsync: Bool = false,
        generics: [Symbol.GenericParameter] = [],
        body: @escaping @Sendable (_ receiver: Value, _ arguments: [Value]) throws -> Value
    ) -> HostSymbol {
        HostSymbol(
            name: name,
            summary: summary,
            kind: .method(
                Symbol.Method(
                    function: signature(parameters, returns, isThrowing, isAsync, generics)
                )
            ),
            body: .method(body)
        )
    }

    /// A method of a type that changes its receiver, like `append`: its body gives the result and
    /// the receiver as it is now.
    public static func mutatingMethod(
        _ name: String,
        summary: String = "",
        parameters: [Symbol.Parameter] = [],
        returns: ScriptType = .void,
        isThrowing: Bool = false,
        isAsync: Bool = false,
        generics: [Symbol.GenericParameter] = [],
        body:
            @escaping @Sendable (_ receiver: Value, _ arguments: [Value]) throws
            -> (result: Value, receiver: Value)
    ) -> HostSymbol {
        HostSymbol(
            name: name,
            summary: summary,
            kind: .method(
                Symbol.Method(
                    function: signature(parameters, returns, isThrowing, isAsync, generics),
                    isMutating: true
                )
            ),
            body: .mutatingMethod(body)
        )
    }

    /// A function of the type itself, as a `static` one is.
    public static func staticMethod(
        _ name: String,
        summary: String = "",
        parameters: [Symbol.Parameter] = [],
        returns: ScriptType = .void,
        isThrowing: Bool = false,
        isAsync: Bool = false,
        generics: [Symbol.GenericParameter] = [],
        body: @escaping @Sendable (_ arguments: [Value]) throws -> Value
    ) -> HostSymbol {
        HostSymbol(
            name: name,
            summary: summary,
            kind: .method(
                Symbol.Method(
                    function: signature(parameters, returns, isThrowing, isAsync, generics),
                    isStatic: true
                )
            ),
            body: .staticMethod(body)
        )
    }

    /// A property a script can read.
    public static func property(
        _ name: String,
        summary: String = "",
        type: ScriptType,
        get: @escaping @Sendable (_ receiver: Value) throws -> Value
    ) -> HostSymbol {
        HostSymbol(
            name: name,
            summary: summary,
            kind: .property(Symbol.Property(variable: Symbol.Variable(type: type))),
            body: .property(get: get)
        )
    }

    /// A property a script can read and assign. `set` gives the receiver as it is now, which is how
    /// a value type changes.
    public static func property(
        _ name: String,
        summary: String = "",
        type: ScriptType,
        get: @escaping @Sendable (_ receiver: Value) throws -> Value,
        set: @escaping @Sendable (_ receiver: Value, _ newValue: Value) throws -> Value
    ) -> HostSymbol {
        HostSymbol(
            name: name,
            summary: summary,
            kind: .property(
                Symbol.Property(variable: Symbol.Variable(type: type, isSettable: true))
            ),
            body: .settableProperty(get: get, set: set)
        )
    }

    /// A property of the type itself.
    public static func staticProperty(
        _ name: String,
        summary: String = "",
        type: ScriptType,
        get: @escaping @Sendable () throws -> Value
    ) -> HostSymbol {
        HostSymbol(
            name: name,
            summary: summary,
            kind: .property(
                Symbol.Property(variable: Symbol.Variable(type: type), isStatic: true)
            ),
            body: .staticProperty(get: get)
        )
    }

    /// How a script makes a value of the type. `returns` is the type it makes, which is an
    /// optional of it for an initializer that can fail: the body gives nothing for a failure.
    public static func initializer(
        summary: String = "",
        parameters: [Symbol.Parameter] = [],
        returns: ScriptType,
        isThrowing: Bool = false,
        body: @escaping @Sendable (_ arguments: [Value]) throws -> Value
    ) -> HostSymbol {
        HostSymbol(
            name: "init",
            summary: summary,
            kind: .initializer(signature(parameters, returns, isThrowing)),
            body: .initializer(body)
        )
    }
}
