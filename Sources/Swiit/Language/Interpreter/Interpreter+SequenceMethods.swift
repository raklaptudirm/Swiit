import SwiitKit

extension Interpreter {
    /// `xs.sorted(by: "size")`: a method the prelude gives every sequence,
    /// called on `items` as a stage of a pipeline is, the items going in
    /// through its input: each one through an item's input, all of them
    /// through a list's, or as they come through a builtin that streams.
    func callSequenceMethod(_ methods: OverloadSet, on items: [Value], _ arguments: [Argument]) throws -> Value {
        let values = try [Argument(label: nil, value: .literal(.list(items)))] + arguments.map { argument -> Argument in
            // `.case` arguments wait for their parameter's type.
            if case .caseLiteral = argument.value { return argument }
            return Argument(label: argument.label, value: .literal(try evaluate(argument.value)))
        }
        let (function, bindings) = try resolve(methods) { try self.bind(values, to: $0) }
        guard let input = function.inputParameter else { return try invoke(function, with: bindings) }
        if input.type.isList, case .native = function.body { return try invoke(function, with: bindings) }
        var rest = bindings
        rest.removeValue(forKey: input.name)
        let name = function.name ?? "closure"
        func item(_ value: Value, as type: TypeAnnotation) throws -> Value {
            guard let conforming = conform(value, to: type) else {
                throw RuntimeError("\(name): input must be \(type), not \(value.typeName) '\(value)'")
            }
            return conforming
        }
        let output: ValueStream
        switch (function.body, input.type) {
        case (.stream(let transform), _):
            output = try transform(self, .elements(of: .list(items)), rest)
        case (_, .list(let element)):
            var arguments = rest
            arguments[input.name] = .list(try items.map { try item($0, as: element) })
            output = .elements(of: try invoke(function, with: arguments))
        default:
            // Once an item, dropping what gives nothing.
            var results: [Value] = []
            for value in items {
                var arguments = rest
                arguments[input.name] = try item(value, as: input.type)
                let result = try invoke(function, with: arguments)
                if result != .nothing { results.append(result) }
            }
            return .list(results)
        }
        var results: [Value] = []
        while let value = try output.next() { results.append(value) }
        return .list(results)
    }
}
