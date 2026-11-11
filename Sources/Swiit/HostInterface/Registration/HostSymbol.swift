import Foundation

/// What a host offers a script: a function, or a member of a type (`HostType.Builder`). It is what a script
/// sees, as a `Symbol` (its name, summary, signature and attributes, which `Interpreter.globals(named:)` says
/// of it as they are), and the Swift that runs when it is used.
///
/// What the Swift of a body may rely on, and what it must do, is in the article "What a Swift body
/// can rely on" (`NativeBodies`).
///
/// The two always agree: the only ways to make one are the functions here, and each makes the
/// `Symbol.Kind` and the body that fit each other, so a static method cannot be given a receiver nor
/// a settable property no setter.
public struct HostSymbol: Sendable {
    /// What a script sees.
    public let symbol: Symbol
    let body: Body
    /// The enums its parameters and result use, which registering it makes known to scripts.
    var enums: [Value.EnumCase.Enumeration] = []

    /// What runs. A body is called with its arguments in declared order, defaults filled in; an
    /// instance member's also with the receiver, which scripts do not see as a parameter.
    enum Body: Sendable {
        /// A function that takes what a call bound by parameter name.
        case function(@Sendable (Arguments) throws -> Value)
        case method(@Sendable (_ receiver: Value, _ arguments: [Value]) throws -> Value)
        /// A method that changes its receiver, like `append`: it changes the receiver in place and
        /// gives its result.
        case mutatingMethod(
            @Sendable (_ receiver: inout Value, _ arguments: [Value]) throws -> Value
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
    var function: (signature: Symbol.Function, call: @Sendable (Arguments) throws -> Value)? {
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
        call: @escaping @Sendable (Arguments) throws -> Value
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
        call: @escaping @Sendable (Arguments) throws -> Value
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

// MARK: Typed functions

extension HostSymbol {
    /// The parameters a Swift closure's argument types make, labeled as `labels` says (`nil` or
    /// missing for none).
    static func parameters<each Argument: ScriptConvertible>(
        _: repeat (each Argument).Type,
        labels: [String?]
    ) -> [Symbol.Parameter] {
        var made: [Symbol.Parameter] = []
        func add<A: ScriptConvertible>(_: A.Type) {
            let label = labels.indices.contains(made.count) ? labels[made.count] : nil
            made.append(
                Symbol.Parameter(label: label, name: label ?? "argument\(made.count)", type: A.self)
            )
        }
        repeat add((each Argument).self)
        return made
    }

    /// The Swift enums the types name, which a script learns by registering what takes or gives
    /// them.
    static func enums<each Argument: ScriptConvertible>(
        _: repeat (each Argument).Type
    ) -> [Value.EnumCase.Enumeration] {
        var found: [Value.EnumCase.Enumeration] = []
        func add<A: ScriptConvertible>(_: A.Type) { found += A.swiitEnums }
        repeat add((each Argument).self)
        return found
    }

    /// A Swift closure as a function scripts can call. Its parameters and result convert as
    /// `ScriptConvertible` says, and a script sees an ordinary function: `labels` are its argument
    /// labels (`nil` or missing for none), and a wrong argument is the usual type error.
    public static func function<each Argument: ScriptConvertible, Result: ScriptConvertible>(
        _ name: String,
        summary: String = "",
        labels: [String?] = [],
        throwing: Bool = false,
        _ body: @escaping @Sendable (repeat each Argument) throws -> Result
    ) -> HostSymbol {
        var symbol = function(
            name: name,
            summary: summary,
            parameters: parameters(repeat (each Argument).self, labels: labels),
            returns: Result.scriptType,
            isThrowing: throwing
        ) { arguments in
            var index = 0
            func next() -> Value {
                defer { index += 1 }
                return arguments[index]
            }
            return try body(repeat try (each Argument)(next())).value
        }
        symbol.enums = enums(repeat (each Argument).self) + Result.swiitEnums
        return symbol
    }

    /// As above, for a closure that returns nothing.
    public static func function<each Argument: ScriptConvertible>(
        _ name: String,
        summary: String = "",
        labels: [String?] = [],
        throwing: Bool = false,
        _ body: @escaping @Sendable (repeat each Argument) throws -> Void
    ) -> HostSymbol {
        var symbol = function(
            name: name,
            summary: summary,
            parameters: parameters(repeat (each Argument).self, labels: labels),
            returns: .void,
            isThrowing: throwing
        ) { arguments in
            var index = 0
            func next() -> Value {
                defer { index += 1 }
                return arguments[index]
            }
            try body(repeat try (each Argument)(next()))
            return .nothing
        }
        symbol.enums = enums(repeat (each Argument).self)
        return symbol
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

    /// A method of a type that changes its receiver, like `append`: its body changes the receiver in
    /// place and gives the result. A body that holds the receiver's contents while it changes them
    /// (a collection) should set the receiver aside first (`receiver = .nothing`) so they are
    /// not copied.
    public static func mutatingMethod(
        _ name: String,
        summary: String = "",
        parameters: [Symbol.Parameter] = [],
        returns: ScriptType = .void,
        isThrowing: Bool = false,
        isAsync: Bool = false,
        generics: [Symbol.GenericParameter] = [],
        body: @escaping @Sendable (_ receiver: inout Value, _ arguments: [Value]) throws -> Value
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

    /// A method of a type, from its whole signature, which says what the parameters above cannot:
    /// `rethrows`, a typed `throws`, the documentation of each parameter.
    public static func method(
        _ name: String,
        summary: String = "",
        attributes: [Symbol.Attribute] = [],
        signature: Symbol.Function,
        body: @escaping @Sendable (_ receiver: Value, _ arguments: [Value]) throws -> Value
    ) -> HostSymbol {
        HostSymbol(
            name: name,
            summary: summary,
            kind: .method(Symbol.Method(function: signature)),
            attributes: attributes,
            body: .method(body)
        )
    }

    /// A method that changes its receiver, from its whole signature.
    public static func mutatingMethod(
        _ name: String,
        summary: String = "",
        attributes: [Symbol.Attribute] = [],
        signature: Symbol.Function,
        body: @escaping @Sendable (_ receiver: inout Value, _ arguments: [Value]) throws -> Value
    ) -> HostSymbol {
        HostSymbol(
            name: name,
            summary: summary,
            kind: .method(Symbol.Method(function: signature, isMutating: true)),
            attributes: attributes,
            body: .mutatingMethod(body)
        )
    }

    /// A function of the type itself, from its whole signature.
    public static func staticMethod(
        _ name: String,
        summary: String = "",
        attributes: [Symbol.Attribute] = [],
        signature: Symbol.Function,
        body: @escaping @Sendable (_ arguments: [Value]) throws -> Value
    ) -> HostSymbol {
        HostSymbol(
            name: name,
            summary: summary,
            kind: .method(Symbol.Method(function: signature, isStatic: true)),
            attributes: attributes,
            body: .staticMethod(body)
        )
    }

    /// An initializer, from its whole signature.
    public static func initializer(
        summary: String = "",
        attributes: [Symbol.Attribute] = [],
        signature: Symbol.Function,
        body: @escaping @Sendable (_ arguments: [Value]) throws -> Value
    ) -> HostSymbol {
        HostSymbol(
            name: "init",
            summary: summary,
            kind: .initializer(signature),
            attributes: attributes,
            body: .initializer(body)
        )
    }

    /// A property a script can read. Reading it needs `await` if it is `isAsync`, and a `try` if it
    /// `throws`.
    public static func property(
        _ name: String,
        summary: String = "",
        attributes: [Symbol.Attribute] = [],
        type: ScriptType,
        isAsync: Bool = false,
        throwing: Symbol.Throwing = .no,
        get: @escaping @Sendable (_ receiver: Value) throws -> Value
    ) -> HostSymbol {
        HostSymbol(
            name: name,
            summary: summary,
            kind: .property(
                Symbol.Property(
                    variable: Symbol.Variable(type: type),
                    isAsync: isAsync,
                    throwing: throwing
                )
            ),
            attributes: attributes,
            body: .property(get: get)
        )
    }

    /// A property a script can read and assign. `set` gives the receiver as it is now, which is how
    /// a value type changes.
    public static func property(
        _ name: String,
        summary: String = "",
        attributes: [Symbol.Attribute] = [],
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
            attributes: attributes,
            body: .settableProperty(get: get, set: set)
        )
    }

    /// A property of the type itself.
    public static func staticProperty(
        _ name: String,
        summary: String = "",
        attributes: [Symbol.Attribute] = [],
        type: ScriptType,
        get: @escaping @Sendable () throws -> Value
    ) -> HostSymbol {
        HostSymbol(
            name: name,
            summary: summary,
            kind: .property(
                Symbol.Property(variable: Symbol.Variable(type: type), isStatic: true)
            ),
            attributes: attributes,
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
