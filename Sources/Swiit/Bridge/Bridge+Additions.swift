import Foundation
import SwiitStandardLibrary

// Members of Swift's types that the generator can't bridge, written by hand.

extension Bridge {
    /// `reduce(into:)`, which changes its accumulator in place, for each of the sequences.
    nonisolated(unsafe) private static let reduceInto = member( // safe: set once, before anything reads it
        .method, "reduce",
        parameters: [Parameter(label: "into", name: "initialResult", type: .parameter("R")),
                     Parameter(label: nil, name: "updateAccumulatingResult",
                               type: .functionType([.inOut(.parameter("R")), .parameter("Element")], .void))],
        returns: .parameter("R"), generics: ["R": []],
        summary: "Combines the items into one value that each step changes in place.") { interpreter, arguments in
        guard let items = Interpreter.items(of: arguments["self"] ?? .nothing) else { throw RuntimeError("reduce needs a sequence") }
        var result = arguments["initialResult"] ?? .nothing
        for item in items { result = try interpreter.callChangingFirst(arguments["updateAccumulatingResult"]!, result, item) }
        return result
    }

    /// `String.Index`: a position in a String, as Swift holds it.
    nonisolated(unsafe) static let stringIndex = BridgedType( // safe: set once, before anything reads it
        name: "String.Index", genericParameters: [], conformances: ["Comparable": [:], "Equatable": [:], "Hashable": [:]],
        associatedTypes: [:], members: [])

    private static let indexType = TypeAnnotation.named("String.Index")

    private static func text(_ arguments: [String: Value]) throws -> String {
        guard case .string(let text)? = arguments["self"] else { throw RuntimeError("expected a String") }
        return text
    }

    static func stringIndexValue(_ value: Value?) throws -> String.Index {
        try SwiftValue.unbox(String.Index.self, value ?? .nothing)
    }

    private static func box(_ index: String.Index) -> Value { SwiftValue.make(index, as: "String.Index") }

    /// A position inside the text (or at its end), which a subscript or `index(…)` needs.
    private static func checked(_ index: String.Index, in text: String, allowingEnd: Bool = false) throws -> String.Index {
        guard index >= text.startIndex, allowingEnd ? index <= text.endIndex : index < text.endIndex else {
            throw RuntimeError("String index is out of bounds")
        }
        return index
    }

    nonisolated(unsafe) private static let stringIndexMembers: [BridgedMember] = [ // safe: set once, before anything reads it
        member(.property, "startIndex", returns: indexType, summary: "The position of the first character.") { _, arguments in
            box(try text(arguments).startIndex)
        },
        member(.property, "endIndex", returns: indexType, summary: "The position after the last character.") { _, arguments in
            box(try text(arguments).endIndex)
        },
        member(.method, "index", parameters: [Parameter(label: "after", name: "i", type: indexType)], returns: indexType,
               summary: "The position after the given one.") { _, arguments in
            let text = try text(arguments)
            return box(text.index(after: try checked(try stringIndexValue(arguments["i"]), in: text)))
        },
        member(.method, "index", parameters: [Parameter(label: "before", name: "i", type: indexType)], returns: indexType,
               summary: "The position before the given one.") { _, arguments in
            let text = try text(arguments)
            let index = try checked(try stringIndexValue(arguments["i"]), in: text, allowingEnd: true)
            guard index > text.startIndex else { throw RuntimeError("String index is out of bounds") }
            return box(text.index(before: index))
        },
        member(.method, "index", parameters: [Parameter(label: nil, name: "i", type: indexType), Parameter(label: "offsetBy", name: "n", type: .int)],
               returns: indexType, summary: "The position a number of characters from the given one.") { _, arguments in
            let text = try text(arguments)
            let offset = try Int(arguments["n"]!)
            let start = try checked(try stringIndexValue(arguments["i"]), in: text, allowingEnd: true)
            guard let moved = text.index(start, offsetBy: offset, limitedBy: offset >= 0 ? text.endIndex : text.startIndex) else {
                throw RuntimeError("String index is out of bounds")
            }
            return box(moved)
        },
        member(.method, "distance", parameters: [Parameter(label: "from", name: "start", type: indexType), Parameter(label: "to", name: "end", type: indexType)],
               returns: .int, summary: "The number of characters between two positions.") { _, arguments in
            let text = try text(arguments)
            let from = try checked(try stringIndexValue(arguments["start"]), in: text, allowingEnd: true)
            let to = try checked(try stringIndexValue(arguments["end"]), in: text, allowingEnd: true)
            return .int(text.distance(from: from, to: to))
        },
        member(.method, "suffix", parameters: [Parameter(label: "from", name: "start", type: indexType)], returns: .named("Substring"),
               summary: "The text from a position to the end.") { _, arguments in
            let text = try text(arguments)
            return SwiftValue.make(text[try checked(try stringIndexValue(arguments["start"]), in: text, allowingEnd: true)...], as: "Substring")
        },
        member(.method, "prefix", parameters: [Parameter(label: "upTo", name: "end", type: indexType)], returns: .named("Substring"),
               summary: "The text before a position.") { _, arguments in
            let text = try text(arguments)
            return SwiftValue.make(text[..<(try checked(try stringIndexValue(arguments["end"]), in: text, allowingEnd: true))], as: "Substring")
        },
        member(.method, "prefix", parameters: [Parameter(label: "through", name: "end", type: indexType)], returns: .named("Substring"),
               summary: "The text up to and including a position.") { _, arguments in
            let text = try text(arguments)
            return SwiftValue.make(text[...(try checked(try stringIndexValue(arguments["end"]), in: text))], as: "Substring")
        },
        member(.method, "firstIndex", parameters: [Parameter(label: "of", name: "element", type: .named("Character"))],
               returns: .optional(indexType), summary: "The position of the first occurrence of a character.") { _, arguments in
            let text = try text(arguments)
            guard let wanted = try? SwiftValue.unbox(Character.self, arguments["element"] ?? .nothing),
                  let found = text.firstIndex(of: wanted) else { return .nothing }
            return box(found)
        },
    ]

    /// `text[index]`, or `text[range]`: a Character, or a Substring.
    static func subscriptString(_ text: String, _ index: Value) throws -> Value {
        if let single = try? stringIndexValue(index) {
            return .string(String(text[try checked(single, in: text)]))
        }
        if case .object(let box as SwiftValue) = index {
            if let range = box.value as? Range<Value> {
                let low = try checked(try stringIndexValue(range.lowerBound), in: text, allowingEnd: true)
                let high = try checked(try stringIndexValue(range.upperBound), in: text, allowingEnd: true)
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
        throw RuntimeError("a String is indexed by String.Index, not \(index.typeName): write s.index(s.startIndex, offsetBy: n)")
    }

    /// `lazy`: the items one at a time, as a Flow, which maps and filters as they are read.
    private static func lazyMember(_ element: TypeAnnotation) -> BridgedMember {
        member(.property, "lazy", returns: .generic("Flow", [element]),
               summary: "The items read one at a time, mapped and filtered as they are read.") { _, arguments in
            guard let items = Interpreter.items(of: arguments["self"] ?? .nothing) else { throw RuntimeError("lazy needs a sequence") }
            return SwiftValue.make(Flow<Value> { items.next() }, as: "Flow")
        }
    }

    nonisolated(unsafe) static let additions: [String: [BridgedMember]] = [ // safe: set once, before anything reads it
        "Array": [reduceInto, lazyMember(.parameter("Element"))], "Set": [reduceInto, lazyMember(.parameter("Element"))],
        "ClosedRange": [reduceInto, lazyMember(.parameter("Bound"))], "Range": [reduceInto, lazyMember(.parameter("Bound"))],
        "Unicode.Scalar": [
            member(.property, "value", returns: .int, summary: "The scalar's number, as Unicode gives it.") { _, arguments in
                .int(Int(try SwiftValue.unbox(Unicode.Scalar.self, arguments["self"] ?? .nothing).value))
            },
        ],
        "Flow": [
            member(.method, "reversed", returns: .generic("Flow", [.parameter("Element")]), summary: "The items in the opposite order.") { _, arguments in
                guard case .object(let box as SwiftValue) = arguments["self"] ?? .nothing, let flow = box.value as? Flow<Value> else { return .nothing }
                var items: [Value] = []
                while let item = try flow.read() { items.append(item) }
                var reversed = items.reversed().makeIterator()
                return SwiftValue.make(Flow<Value> { reversed.next() }, as: "Flow")
            },
            member(.property, "first", returns: .optional(.parameter("Element")),
                   summary: "The first item, if there is one.") { _, arguments in
                guard case .object(let box as SwiftValue) = arguments["self"] ?? .nothing, let flow = box.value as? Flow<Value> else { return .nothing }
                return try flow.read() ?? .nothing
            },
            member(.method, "first", parameters: [Parameter(label: "where", name: "predicate", type: .functionType([.parameter("Element")], .bool))],
                   returns: .optional(.parameter("Element")), summary: "The first item the predicate accepts.") { interpreter, arguments in
                guard case .object(let box as SwiftValue) = arguments["self"] ?? .nothing, let flow = box.value as? Flow<Value> else { return .nothing }
                while let item = try flow.read() {
                    if try interpreter.call(arguments["predicate"]!, with: [item]) == .bool(true) { return item }
                }
                return .nothing
            },
            member(.method, "contains", parameters: [Parameter(label: "where", name: "predicate", type: .functionType([.parameter("Element")], .bool))],
                   returns: .bool, summary: "Whether the predicate accepts an item.") { interpreter, arguments in
                guard case .object(let box as SwiftValue) = arguments["self"] ?? .nothing, let flow = box.value as? Flow<Value> else { return .bool(false) }
                while let item = try flow.read() {
                    if try interpreter.call(arguments["predicate"]!, with: [item]) == .bool(true) { return .bool(true) }
                }
                return .bool(false)
            },
        ],
        "String": stringIndexMembers + [
            member(.initializer, "init", isStatic: true,
                   parameters: [Parameter(label: nil, name: "value", type: .parameter("T"))], returns: .string,
                   generics: ["T": ["CustomStringConvertible"]],
                   summary: "The text of a value that has one: String(5), String(2.5).") { interpreter, arguments in
                .string(try interpreter.describing(arguments["value"] ?? .nothing))
            },
        ],
        "Int": [
            member(.initializer, "init", isStatic: true, parameters: [Parameter(label: nil, name: "value", type: .int)], returns: .int,
                   summary: "The same integer: Int(x) of an Int, which also stands for the fixed-width integers.") { _, arguments in
                arguments["value"] ?? .nothing
            },
        ],
        "Dictionary": [
            member(.initializer, "init", isStatic: true,
                   parameters: [Parameter(label: "grouping", name: "values", type: .someSequence(.parameter("E"))),
                                Parameter(label: "by", name: "keyForValue", type: .functionType([.parameter("E")], .parameter("K")))],
                   returns: .dictionary(.parameter("K"), .list(.parameter("E"))), generics: ["E": [], "K": ["Hashable"]],
                   summary: "The values in lists, by the key each gives.") { interpreter, arguments in
                guard let items = Interpreter.items(of: arguments["values"] ?? .nothing) else { throw RuntimeError("grouping needs a sequence") }
                var order: [Value] = []
                var groups: [Value: [Value]] = [:]
                for item in items {
                    let key = try interpreter.call(arguments["keyForValue"]!, with: [item])
                    if groups[key] == nil { order.append(key) }
                    groups[key, default: []].append(item)
                }
                return .dictionary(ValueDictionary(order.map { ($0, Value.list(groups[$0]!)) }))
            },
        ],
    ]
}
