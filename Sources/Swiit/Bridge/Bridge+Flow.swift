import Foundation

// `Flow`, the items read one at a time with the work done as each is asked for, by hand: the generator reads Swift's own
// modules, and this one is Swiit's.

extension Bridge {
    private static let element = TypeAnnotation.parameter("Element")
    private static func flow(_ element: TypeAnnotation) -> TypeAnnotation { .generic("Flow", [element]) }

    private static func receiver(_ arguments: [String: Value]) throws -> Flow<Value> {
        try SwiftValue.unbox(Flow<Value>.self, arguments["self"] ?? .nothing)
    }

    private static func make(_ flow: Flow<Value>) -> Value { SwiftValue.make(flow, as: "Flow") }

    nonisolated(unsafe) static let flowType = BridgedType( // safe: set once, before anything reads it
        name: "Flow", genericParameters: ["Element"], conformances: [:], associatedTypes: [:], members: [
            member(.initializer, "init", isStatic: true,
                   parameters: [Parameter(label: nil, name: "read", type: .functionType([], .optional(element), throws: true))],
                   returns: flow(element), generics: ["Element": []], summary: "") { interpreter, arguments in
                make(Flow<Value> { bridgeOptional(try bridgeClosure(interpreter, arguments["read"]!)([])) { $0 } })
            },
            member(.initializer, "init", isStatic: true,
                   parameters: [Parameter(label: nil, name: "items", type: .someSequence(element))],
                   returns: flow(element), generics: ["Element": []], summary: "The items of any sequence.") { _, arguments in
                make(Flow<Value>(try bridgeSequence(arguments["items"]!)))
            },
            member(.method, "filter",
                   parameters: [Parameter(label: nil, name: "isIncluded", type: .functionType([element], .bool, throws: true))],
                   returns: flow(element), generics: ["Element": []], summary: "The items for which the predicate returns true.") { interpreter, arguments in
                let predicate = bridgeClosure(interpreter, arguments["isIncluded"]!)
                return make(try receiver(arguments).filter { try Bool(try predicate([$0])) })
            },
            member(.method, "map",
                   parameters: [Parameter(label: nil, name: "transform", type: .functionType([element], .parameter("T"), throws: true))],
                   returns: flow(.parameter("T")), generics: ["Element": [], "T": []],
                   summary: "Each item transformed, nil results included, as Swift's map.") { interpreter, arguments in
                let transform = bridgeClosure(interpreter, arguments["transform"]!)
                return make(try receiver(arguments).map { try transform([$0]) })
            },
            member(.method, "compactMap",
                   parameters: [Parameter(label: nil, name: "transform", type: .functionType([element], .optional(.parameter("T")), throws: true))],
                   returns: flow(.parameter("T")), generics: ["Element": [], "T": []],
                   summary: "Each item transformed, nil results dropped.") { interpreter, arguments in
                let transform = bridgeClosure(interpreter, arguments["transform"]!)
                return make(try receiver(arguments).compactMap { bridgeOptional(try transform([$0])) { $0 } })
            },
            member(.method, "prefix", parameters: [Parameter(label: nil, name: "maxLength", type: .int, defaultValue: .literal(.int(1)))],
                   returns: flow(element), generics: ["Element": []], summary: "The first items; stops reading after them.") { _, arguments in
                make(try receiver(arguments).prefix(try Int(arguments["maxLength"]!)))
            },
        ])
}
