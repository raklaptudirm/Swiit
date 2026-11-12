import Foundation

extension Interpreter {
    // swiftlint:disable function_body_length - one branch for each case; a long walk over every case; splitting it is item 17 of Docs/agenda.md
    /// Functions Swift's standard library has at the top level, which aren't
    /// members of a type, so the bridge has no type to put them on.
    func installLanguageFunctions() {
        nonisolated(unsafe) let interpreter = self  // safe: runs holding the interpreter lock
        func declare(_ export: HostSymbol) {
            scopes[0].declare(hostFunction(export), named: export.name)
        }
        let condition = Symbol.Parameter(label: nil, name: "condition", type: .bool)
        let message = Symbol.Parameter(
            label: nil,
            name: "message",
            type: .string,
            defaultValue: .string("")
        )
        for (name, summary) in [
            ("assert", "Stops with the message unless the condition holds."),
            ("precondition", "Stops with the message unless the condition holds."),
        ] {
            declare(
                HostSymbol.function(
                    name: name,
                    summary: summary,
                    parameters: [condition, message],
                    returnType: nil,
                    isThrowing: false,
                    call: { arguments in
                        guard case .bool(true)? = arguments["condition"] else {
                            let text = arguments["message"].map { "\($0)" } ?? ""
                            throw RuntimeError(
                                "\(name == "assert" ? "Assertion" : "Precondition") failed"
                                    + (text.isEmpty ? "" : ": \(text)")
                            )
                        }
                        return .nothing
                    }
                )
            )
        }
        for name in ["fatalError", "preconditionFailure"] {
            declare(
                HostSymbol.function(
                    name: name,
                    summary: "Stops with the message.",
                    parameters: [message],
                    returnType: nil,
                    isThrowing: false,
                    call: { arguments in
                        let text = arguments["message"].map { "\($0)" } ?? ""
                        throw RuntimeError(
                            (name == "fatalError" ? "Fatal error" : "Precondition failed")
                                + (text.isEmpty ? "" : ": \(text)")
                        )
                    }
                )
            )
        }
        // `type(of: x)`: the type of a value, as the value that stands for the type.
        scopes[0]
            .declare(
                Function(
                    name: "type",
                    parameters: [Parameter(label: "of", name: "value", type: .parameter("T"))],
                    returnType: .metatype(.parameter("T")),
                    body: .native { interpreter, arguments in
                        interpreter.typeObject(of: arguments["value"] ?? .nothing)
                    },
                    documentation: Documentation(summary: "The type of a value.", parameters: [:]),
                    generics: ["T"]
                ),
                named: "type"
            )
        for (name, isThrowing) in [("withTaskGroup", false), ("withThrowingTaskGroup", true)] {
            scopes[0].declare(Bridge.taskGroupFunction(name, isThrowing: isThrowing), named: name)
        }
        // What a Mirror shows: a struct's or class's stored properties, an array's items, a tuple's
        // elements.
        scopes[0]
            .declare(
                Function(
                    name: "__mirrorChildren",
                    parameters: [Parameter(label: nil, name: "subject", type: .any)],
                    returnType: .list(
                        .tuple([
                            .init(label: "label", type: .optional(.string)),
                            .init(label: "value", type: .any),
                        ])
                    ),
                    body: .native { _, arguments in
                        func child(_ label: String?, _ value: Value) -> Value {
                            Value(
                                record:
                                    Value.Record([
                                        "label": label.map(Value.string) ?? .nothing,
                                        "value": value,
                                    ])
                            )
                        }
                        switch (arguments["subject"] ?? .nothing).storage {
                        case .tuple(let tuple):
                            return .list(tuple.map { child($0.key, $0.value) })
                        case .structure(let structure):
                            return .list(structure.map { child($0.key, $0.value) })
                        case .list(let items): return .list(items.map { child(nil, $0) })
                        case .dictionary(let dictionary):
                            return .list(
                                dictionary.sortedForDisplay.map {
                                    child(
                                        nil,
                                        Value(
                                            record: Value.Record(["key": $0.key, "value": $0.value])
                                        )
                                    )
                                }
                            )
                        case .object(let instance as ClassInstance):
                            return .list(
                                instance.type.allStored.map {
                                    child($0.name, instance.storage[$0.name] ?? .nothing)
                                }
                            )
                        case .enumValue(let value):
                            return .list(value.values.map { child(nil, $0) })
                        default: return .list([])
                        }
                    },
                    documentation: Documentation(
                        summary: "The pieces of a value, for Mirror.",
                        parameters: [:]
                    )
                ),
                named: "__mirrorChildren"
            )
        // `weak var x = e`: what e is, held weakly if it is a class instance.
        scopes[0]
            .declare(
                Function(
                    name: InternalName.weak,
                    parameters: [Parameter(label: nil, name: "x", type: .parameter("T"))],
                    returnType: .parameter("T"),
                    body: .native { _, arguments in
                        if case .object(let instance as ClassInstance)? = arguments["x"]?.storage {
                            return .object(WeakReference(instance))
                        }
                        if arguments["x"] == nil || arguments["x"] == .nothing {
                            return .object(WeakReference(nil))
                        }
                        return arguments["x"] ?? .nothing
                    },
                    documentation: Documentation(
                        summary: "A weak variable's initial value.",
                        parameters: [:]
                    ),
                    generics: ["T"]
                ),
                named: InternalName.weak
            )
        // `let x: Int`, given its value later.
        scopes[0]
            .declare(
                Function(
                    name: InternalName.uninitialized,
                    parameters: [],
                    returnType: nil,
                    body: .native { _, _ in .nothing },
                    documentation: Documentation(
                        summary: "A variable declared without a value.",
                        parameters: [:]
                    )
                ),
                named: InternalName.uninitialized
            )
        // `o?.a.b`: the rest of the chain, if `o` has a value, as an optional.
        scopes[0]
            .declare(
                Function(
                    name: InternalName.chain,
                    parameters: [
                        Parameter(label: nil, name: "base", type: .optional(.parameter("T"))),
                        Parameter(
                            label: nil,
                            name: "rest",
                            type: .functionType([.parameter("T")], .parameter("R"), throws: true)
                        ),
                    ],
                    returnType: .optional(.parameter("R")),
                    body: .native { interpreter, arguments in
                        guard let base = arguments["base"], base != .nothing else {
                            return .nothing
                        }
                        return try interpreter.call(arguments["rest"]!, with: [base])
                    },
                    documentation: Documentation(
                        summary: "The rest of an optional chain.",
                        parameters: [:]
                    ),
                    isRethrowing: true,
                    generics: ["T", "R"],
                    flattensResult: true
                ),
                named: InternalName.chain
            )
        // `Optional(x)`: x, as an optional.
        scopes[0]
            .declare(
                Function(
                    name: InternalName.some,
                    parameters: [Parameter(label: nil, name: "x", type: .parameter("T"))],
                    returnType: .optional(.parameter("T")),
                    body: .native { _, arguments in arguments["x"] ?? .nothing },
                    documentation: Documentation(summary: "Optional(x).", parameters: [:]),
                    generics: ["T"]
                ),
                named: InternalName.some
            )
        // `a === b`: whether two class instances are the same one.
        scopes[0]
            .declare(
                Function(
                    name: "===",
                    parameters: [
                        Parameter(label: nil, name: "a", type: .any),
                        Parameter(label: nil, name: "b", type: .any),
                    ],
                    returnType: .bool,
                    body: .native { _, arguments in
                        guard case .object(let a)? = arguments["a"]?.storage,
                            case .object(let b)? = arguments["b"]?.storage
                        else {
                            return .bool(false)
                        }
                        return .bool(a === b)
                    },
                    documentation: Documentation(
                        summary: "Whether two references are to the same instance.",
                        parameters: [:]
                    )
                ),
                named: "==="
            )
        // The functions of Foundation's math, on Doubles.
        let unary: [(String, @Sendable (Double) -> Double)] = [
            ("sqrt", { $0.squareRoot() }), ("floor", { $0.rounded(.down) }),
            ("ceil", { $0.rounded(.up) }),
            ("trunc", { $0.rounded(.towardZero) }),
            ("round", { $0.rounded(.toNearestOrAwayFromZero) }), ("sin", sin), ("cos", cos),
            ("tan", tan),
            ("asin", asin), ("acos", acos),
            ("atan", atan), ("exp", exp), ("log", log), ("log2", log2), ("log10", log10),
            ("fabs", { Swift.abs($0) }),
        ]
        for (name, function) in unary {
            declare(
                HostSymbol.function(
                    name: name,
                    summary: "\(name) of a Double.",
                    parameters: [Symbol.Parameter(label: nil, name: "x", type: .double)],
                    returnType: .double,
                    isThrowing: false,
                    call: { arguments in .double(function(arguments["x"]?.asDouble ?? 0)) }
                )
            )
        }
        let binary: [(String, @Sendable (Double, Double) -> Double)] = [
            ("pow", pow), ("atan2", atan2), ("fmod", fmod), ("hypot", hypot),
        ]
        for (name, function) in binary {
            declare(
                HostSymbol.function(
                    name: name,
                    summary: "\(name) of two Doubles.",
                    parameters: [
                        Symbol.Parameter(label: nil, name: "x", type: .double),
                        Symbol.Parameter(label: nil, name: "y", type: .double),
                    ],
                    returnType: .double,
                    isThrowing: false,
                    call: { arguments in
                        .double(
                            function(arguments["x"]?.asDouble ?? 0, arguments["y"]?.asDouble ?? 0)
                        )
                    }
                )
            )
        }
        // The standard library's own top-level functions, as the generator reads them (`zip`, `swap`, `stride`).
        for function in StandardLibraryBridge.functions { declare(function) }
        // `abs`, `min` and `max`, for the numbers and strings there are.
        for (type, name) in [(ScriptType.int, "Int"), (ScriptType.double, "Double")] {
            declare(
                HostSymbol.function(
                    name: "abs",
                    summary: "The magnitude of an \(name).",
                    parameters: [Symbol.Parameter(label: nil, name: "x", type: type)],
                    returnType: type,
                    isThrowing: false,
                    call: { arguments in
                        switch arguments["x"]?.storage {
                        case .int(let n)?:
                            guard n != Int.min else { throw RuntimeError("arithmetic overflow") }
                            return .int(Swift.abs(n))
                        case .double(let d)?: return .double(Swift.abs(d))
                        default: return .nothing
                        }
                    }
                )
            )
        }
        for type in [ScriptType.int, .double, .string] {
            for (name, picksLess) in [("min", true), ("max", false)] {
                declare(
                    HostSymbol.function(
                        name: name,
                        summary: "The \(picksLess ? "smallest" : "largest") of its arguments.",
                        parameters: [
                            Symbol.Parameter(label: nil, name: "x", type: type),
                            Symbol.Parameter(label: nil, name: "y", type: type),
                            Symbol.Parameter(
                                label: nil,
                                name: "rest",
                                type: type,
                                variadic: true
                            ),
                        ],
                        returnType: type,
                        isThrowing: false,
                        call: { arguments in
                            var values = [arguments["x"] ?? .nothing, arguments["y"] ?? .nothing]
                            if case .list(let rest)? = arguments["rest"]?.storage { values += rest }
                            func before(_ a: Value, _ b: Value) -> Bool {
                                switch (a.storage, b.storage) {
                                case (.int(let x), .int(let y)): return x < y
                                case (.double(let x), .double(let y)): return x < y
                                case (.string(let x), .string(let y)): return x < y
                                default: return false
                                }
                            }
                            var best = values[0]
                            for value in values.dropFirst()
                            where picksLess ? before(value, best) : before(best, value) {
                                best = value
                            }
                            return best
                        }
                    )
                )
            }
        }
    }
    // swiftlint:enable function_body_length

    /// What stands for a value's type: the struct's or enum's own, or Swift's by name.
    func typeObject(of value: Value) -> Value {
        let name: String
        switch value.storage {
        case _ where Value.Builtin(value.storage) != nil: name = Value.Builtin(value.storage)!.name
        case .enumValue(let enumValue): return .object(enumValue.type)
        case .tuple:
            // A tuple is of the type its elements make: `(x: Int, Double)`.
            return .object(
                BridgedTypeName(TypeChecker(interpreter: self).type(of: value).description)
            )
        case .structure(let structure):
            guard let type = structType(named: structure.typeName) else {
                return .object(
                    BridgedTypeName(TypeChecker(interpreter: self).type(of: value).description)
                )
            }
            return .object(type)
        case .object(let instance as ClassInstance): return .object(instance.type)
        case .object(let box as SwiftValue): name = box.typeName
        // The type of a type: `Int.Type`.
        case .object(let type as ClassType): return .object(BridgedTypeName(type.name + ".Type"))
        case .object(let type as StructType): return .object(BridgedTypeName(type.name + ".Type"))
        case .object(let type as Value.EnumCase.Enumeration):
            return .object(BridgedTypeName(type.name + ".Type"))
        case .object(let type as BridgedTypeName):
            return .object(BridgedTypeName(type.name + ".Type"))
        default: return .nothing
        }
        return lookup(name)?.value ?? .nothing
    }
}
