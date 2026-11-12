import Foundation

// Members of Swift's types that the generator can't bridge, written by hand.

extension Bridge {
    /// The interpreter running the script code that called a body.
    static func running() throws -> Interpreter {
        guard let interpreter = Interpreter.running else {
            throw RuntimeError("this runs only inside a script")
        }
        return interpreter
    }

    private static func text(_ receiver: Value) throws -> String {
        guard case .string(let text) = receiver.storage else {
            throw RuntimeError("expected a String")
        }
        return text
    }

    /// What the table adds to the type named, lowered as the generated members are.
    static func additions(to typeName: String) -> [BridgedMember] {
        BridgedMember.bridged(additionTable[typeName] ?? [], in: typeName)
    }

    static let discardable = [Symbol.Attribute(name: "discardableResult")]

    /// Members of Swift's types that the generator can't bridge, by the type that has them.
    private static let additionTable: [String: [HostSymbol]] = [
        "Unicode.Scalar": [
            .property(
                "value",
                summary: "The scalar's number, as Unicode gives it.",
                type: .int
            ) { receiver in
                .int(Int(try SwiftValue.unbox(Unicode.Scalar.self, receiver).value))
            }
        ],
        "String": [
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
