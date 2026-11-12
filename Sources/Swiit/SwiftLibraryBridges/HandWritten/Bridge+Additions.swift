import Foundation

// Members of Swift's types that the generator can't bridge, written by hand.

extension Bridge {
    /// `reduce(into:)`, which changes its accumulator in place, for each of the sequences.
    private static let reduceInto = HostSymbol.method(
        "reduce",
        summary: "Combines the items into one value that each step changes in place.",
        signature: Symbol.Function(
            parameters: [
                Symbol.Parameter(label: "into", name: "initialResult", type: .parameter("R")),
                Symbol.Parameter(
                    name: "updateAccumulatingResult",
                    type: .function(
                        parameters: [.inOut(.parameter("R")), .parameter("Element")],
                        returns: .void
                    )
                ),
            ],
            returns: .parameter("R"),
            generics: ["R"]
        )
    ) { receiver, arguments in
        guard let items = Interpreter.items(of: receiver) else {
            throw RuntimeError("reduce needs a sequence")
        }
        let interpreter = try running()
        var result = arguments[0]
        for item in items {
            result = try interpreter.callChangingFirst(arguments[1], result, [item])
        }
        return result
    }

    /// The interpreter running the script code that called a body.
    static func running() throws -> Interpreter {
        guard let interpreter = Interpreter.running else {
            throw RuntimeError("this runs only inside a script")
        }
        return interpreter
    }

    /// `String.Index`: a position in a String, as Swift holds it.
    static let stringIndex: HostType = {
        var type = HostType(name: "String.Index")
        type.conformances = ["Comparable": [], "Equatable": [], "Hashable": []]
        return type
    }()

    private static let indexType = ScriptType.named("String.Index")

    private static func text(_ receiver: Value) throws -> String {
        guard case .string(let text) = receiver.storage else {
            throw RuntimeError("expected a String")
        }
        return text
    }

    static func stringIndexValue(_ value: Value?) throws -> String.Index {
        try SwiftValue.unbox(String.Index.self, value ?? .nothing)
    }

    private static func box(_ index: String.Index) -> Value {
        SwiftValue.make(index, as: "String.Index")
    }

    /// A position inside the text (or at its end), which a subscript or `index(…)` needs.
    private static func checked(
        _ index: String.Index,
        in text: String,
        allowingEnd: Bool = false
    ) throws -> String.Index {
        guard index >= text.startIndex, allowingEnd ? index <= text.endIndex : index < text.endIndex
        else {
            throw RuntimeError("String index is out of bounds")
        }
        return index
    }

    private static let stringIndexMembers: [HostSymbol] = [
        .property(
            "startIndex",
            summary: "The position of the first character.",
            type: indexType
        ) { receiver in
            box(try text(receiver).startIndex)
        },
        .property(
            "endIndex",
            summary: "The position after the last character.",
            type: indexType
        ) { receiver in
            box(try text(receiver).endIndex)
        },
        .method(
            "index",
            summary: "The position after the given one.",
            parameters: [Symbol.Parameter(label: "after", name: "i", type: indexType)],
            returns: indexType
        ) { receiver, arguments in
            let text = try text(receiver)
            return box(
                text.index(after: try checked(try stringIndexValue(arguments[0]), in: text))
            )
        },
        .method(
            "index",
            summary: "The position before the given one.",
            parameters: [Symbol.Parameter(label: "before", name: "i", type: indexType)],
            returns: indexType
        ) { receiver, arguments in
            let text = try text(receiver)
            let index = try checked(
                try stringIndexValue(arguments[0]),
                in: text,
                allowingEnd: true
            )
            guard index > text.startIndex else {
                throw RuntimeError("String index is out of bounds")
            }
            return box(text.index(before: index))
        },
        .method(
            "index",
            summary: "The position a number of characters from the given one.",
            parameters: [
                Symbol.Parameter(name: "i", type: indexType),
                Symbol.Parameter(label: "offsetBy", name: "n", type: .int),
            ],
            returns: indexType
        ) { receiver, arguments in
            let text = try text(receiver)
            let offset = try Int(arguments[1])
            let start = try checked(
                try stringIndexValue(arguments[0]),
                in: text,
                allowingEnd: true
            )
            guard
                let moved = text.index(
                    start,
                    offsetBy: offset,
                    limitedBy: offset >= 0 ? text.endIndex : text.startIndex
                )
            else {
                throw RuntimeError("String index is out of bounds")
            }
            return box(moved)
        },
        .method(
            "distance",
            summary: "The number of characters between two positions.",
            parameters: [
                Symbol.Parameter(label: "from", name: "start", type: indexType),
                Symbol.Parameter(label: "to", name: "end", type: indexType),
            ],
            returns: .int
        ) { receiver, arguments in
            let text = try text(receiver)
            let from = try checked(
                try stringIndexValue(arguments[0]),
                in: text,
                allowingEnd: true
            )
            let to = try checked(
                try stringIndexValue(arguments[1]),
                in: text,
                allowingEnd: true
            )
            return .int(text.distance(from: from, to: to))
        },
        .method(
            "suffix",
            summary: "The text from a position to the end.",
            parameters: [Symbol.Parameter(label: "from", name: "start", type: indexType)],
            returns: .named("Substring")
        ) { receiver, arguments in
            let text = try text(receiver)
            let start = try checked(try stringIndexValue(arguments[0]), in: text, allowingEnd: true)
            return SwiftValue.make(text[start...], as: "Substring")
        },
        .method(
            "prefix",
            summary: "The text before a position.",
            parameters: [Symbol.Parameter(label: "upTo", name: "end", type: indexType)],
            returns: .named("Substring")
        ) { receiver, arguments in
            let text = try text(receiver)
            let end = try checked(try stringIndexValue(arguments[0]), in: text, allowingEnd: true)
            return SwiftValue.make(text[..<end], as: "Substring")
        },
        .method(
            "prefix",
            summary: "The text up to and including a position.",
            parameters: [Symbol.Parameter(label: "through", name: "end", type: indexType)],
            returns: .named("Substring")
        ) { receiver, arguments in
            let text = try text(receiver)
            let end = try checked(try stringIndexValue(arguments[0]), in: text)
            return SwiftValue.make(text[...end], as: "Substring")
        },
        .method(
            "firstIndex",
            summary: "The position of the first occurrence of a character.",
            parameters: [Symbol.Parameter(label: "of", name: "element", type: .named("Character"))],
            returns: .optional(indexType)
        ) { receiver, arguments in
            let text = try text(receiver)
            guard
                let wanted = try? SwiftValue.unbox(Character.self, arguments[0]),
                let found = text.firstIndex(of: wanted)
            else { return .nothing }
            return box(found)
        },
    ]

    /// `text[index]`, or `text[range]`: a Character, or a Substring.
    static func subscriptString(_ text: String, _ index: Value) throws -> Value {
        if let single = try? stringIndexValue(index) {
            return .string(String(text[try checked(single, in: text)]))
        }
        if case .object(let box as SwiftValue) = index.storage {
            if let range = box.value as? Range<Value> {
                let low = try checked(
                    try stringIndexValue(range.lowerBound),
                    in: text,
                    allowingEnd: true
                )
                let high = try checked(
                    try stringIndexValue(range.upperBound),
                    in: text,
                    allowingEnd: true
                )
                guard low <= high else { throw RuntimeError("String index range is out of bounds") }
                return SwiftValue.make(text[low..<high], as: "Substring")
            }
            if let range = box.value as? ClosedRange<Value> {
                let low = try checked(try stringIndexValue(range.lowerBound), in: text)
                let high = try checked(try stringIndexValue(range.upperBound), in: text)
                guard low <= high else { throw RuntimeError("String index range is out of bounds") }
                return SwiftValue.make(text[low...high], as: "Substring")
            }
        }
        throw RuntimeError(
            "a String is indexed by String.Index, not \(index.typeName): write s.index(s.startIndex, offsetBy: n)"
        )
    }

    /// `lazy`, which Swiit reads as the sequence itself: its operators run all at once, not as
    /// items are asked for, which a finite sequence's result cannot tell.
    private static func lazyMember(_ sequence: ScriptType) -> HostSymbol {
        .property(
            "lazy",
            summary: "The sequence itself: Swiit does not defer the work of its operators.",
            type: sequence
        ) { receiver in receiver }
    }

    /// What the table adds to the type named, lowered as the generated members are.
    static func additions(to typeName: String) -> [BridgedMember] {
        BridgedMember.bridged(additionTable[typeName] ?? [], in: typeName)
    }

    static let discardable = [Symbol.Attribute(name: "discardableResult")]

    /// Members of Swift's types that the generator can't bridge, by the type that has them.
    private static let additionTable: [String: [HostSymbol]] = [
        "Array": [reduceInto, lazyMember(.list(.parameter("Element")))],
        "Set": [reduceInto, lazyMember(.named("Set", [.parameter("Element")]))],
        "ClosedRange": [reduceInto, lazyMember(.named("ClosedRange", [.parameter("Bound")]))],
        "Range": [reduceInto, lazyMember(.named("Range", [.parameter("Bound")]))],
        "Unicode.Scalar": [
            .property(
                "value",
                summary: "The scalar's number, as Unicode gives it.",
                type: .int
            ) { receiver in
                .int(Int(try SwiftValue.unbox(Unicode.Scalar.self, receiver).value))
            }
        ],
        "String": stringIndexMembers + [
            .method(
                "replacingOccurrences",
                summary: "The text with every `target` replaced by `replacement`.",
                parameters: [
                    Symbol.Parameter(label: "of", name: "target", type: .string),
                    Symbol.Parameter(label: "with", name: "replacement", type: .string),
                ],
                returns: .string
            ) { receiver, arguments in
                let text = try text(receiver)
                guard case .string(let target) = arguments[0].storage,
                    case .string(let replacement) = arguments[1].storage, !target.isEmpty
                else { return .string(text) }
                return .string(
                    text.split(separator: target, omittingEmptySubsequences: false)
                        .joined(separator: replacement)
                )
            },
            .method(
                "components",
                summary: "The parts of the text between the `separator`s.",
                parameters: [
                    Symbol.Parameter(label: "separatedBy", name: "separator", type: .string)
                ],
                returns: .list(.string)
            ) { receiver, arguments in
                let text = try text(receiver)
                guard case .string(let separator) = arguments[0].storage, !separator.isEmpty
                else {
                    return .list([.string(text)])
                }
                return .list(
                    text.split(separator: separator, omittingEmptySubsequences: false)
                        .map { .string(String($0)) }
                )
            },
            .initializer(
                summary: "The text of a value that has one: String(5), String(2.5).",
                attributes: discardable,
                signature: Symbol.Function(
                    parameters: [Symbol.Parameter(name: "value", type: .parameter("T"))],
                    returns: .string,
                    generics: [
                        Symbol.GenericParameter(
                            name: "T",
                            constraints: [.conforms(to: "CustomStringConvertible")]
                        )
                    ]
                )
            ) { arguments in
                .string(try running().describing(arguments[0]))
            },
        ],
        "Int": [
            .initializer(
                summary:
                    "The same integer: Int(x) of an Int, which also stands for the fixed-width integers.",
                attributes: discardable,
                signature: Symbol.Function(
                    parameters: [Symbol.Parameter(name: "value", type: .int)],
                    returns: .int
                )
            ) { arguments in arguments[0] }
        ],
        "Dictionary": [
            .initializer(
                summary: "The values in lists, by the key each gives.",
                attributes: discardable,
                signature: Symbol.Function(
                    parameters: [
                        Symbol.Parameter(
                            label: "grouping",
                            name: "values",
                            type: .named(.sequence, [.parameter("E")])
                        ),
                        Symbol.Parameter(
                            label: "by",
                            name: "keyForValue",
                            type: .function(parameters: [.parameter("E")], returns: .parameter("K"))
                        ),
                    ],
                    returns: .dictionary(.parameter("K"), .list(.parameter("E"))),
                    generics: [
                        "E",
                        Symbol.GenericParameter(name: "K", constraints: [.hashable]),
                    ]
                )
            ) { arguments in
                guard let items = Interpreter.items(of: arguments[0]) else {
                    throw RuntimeError("grouping needs a sequence")
                }
                let interpreter = try running()
                var order: [Value] = []
                var groups: [Value: [Value]] = [:]
                for item in items {
                    let key = try interpreter.call(arguments[1], with: [item])
                    if groups[key] == nil { order.append(key) }
                    groups[key, default: []].append(item)
                }
                return .dictionary(groups.mapValues { Value.list($0) })
            }
        ],
    ]
}
