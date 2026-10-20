
extension Interpreter {
    /// `xs.sorted(by: "size")`: a method the prelude gives every sequence,
    /// called on `items`, which go in through its `self`.
    func callSequenceMethod(_ methods: OverloadSet, on items: [Value], _ arguments: [Argument]) throws -> Value {
        let values = try [Argument(label: nil, value: .literal(.list(items)))] + arguments.map { argument -> Argument in
            // `.case` arguments wait for their parameter's type.
            if case .caseLiteral = argument.value { return argument }
            return Argument(label: argument.label, value: .literal(try evaluate(argument.value)))
        }
        let (function, bindings) = try resolve(methods) { try self.bind(values, to: $0) }
        return try invoke(function, with: bindings)
    }
}
