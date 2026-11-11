import Foundation

/// Every function declared under one name. A name declared with `func` is
/// always bound to one of these, even with a single candidate.
final class OverloadSet: Callable, @unchecked Sendable {  // safe: its state is touched only holding the interpreter lock
    let name: String
    let candidates: [Function]

    init(name: String, candidates: [Function]) {
        self.name = name
        self.candidates = candidates
    }

    var description: String {
        "(Function)"
    }
}

extension Function {
    /// Like a Swift declaration: `greet(_ name: String, times: Int) -> String`.
    /// A Swift member's receiver, as a stage's input, isn't written.
    var signature: String {
        let written = parameters.filter { $0.name != "self" }
            .map { parameter -> String in
                let name =
                    parameter.label == parameter.name
                    ? parameter.name : "\(parameter.label ?? "_") \(parameter.name)"
                return "\(name): \(parameter.type)" + (parameter.variadic ? "..." : "")
            }
        let returns = returnType.flatMap { $0 == .void ? nil : " -> \($0)" } ?? ""
        return "\(name ?? "closure")(\(written.joined(separator: ", ")))\(returns)"
    }
}

/// `\.size` or `\.status.code`: reads the path of members from a value.
/// Where a function is wanted it's one, as in Swift: `xs.map(\.name)`.
final class KeyPathValue: Callable, @unchecked Sendable {  // safe: its state is touched only holding the interpreter lock
    let path: [String]

    init(path: [String]) {
        self.path = path
    }

    var description: String { "\\." + path.joined(separator: ".") }

    func read(from value: Value, in interpreter: Interpreter) throws -> Value {
        try path.reduce(value) { try interpreter.member($1, of: $0) }
    }
}

extension TypeAnnotation {
    var isList: Bool {
        if case .list = self { true } else { false }
    }

    /// Whether a closure can be passed for it.
    var acceptsFunction: Bool {
        switch self {
        case .function, .functionType, .any: true
        case .optional(let wrapped): wrapped.acceptsFunction
        default: false
        }
    }
}

// MARK: Declaring builtins

extension Function {
    /// A builtin written in Swift, with its documentation.
    static func builtin(
        _ name: String,
        _ summary: String,
        _ parameters: [Parameter],
        docs: [String: String] = [:],
        _ body: FunctionBody
    ) -> Function {
        Function(
            name: name,
            parameters: parameters,
            returnType: nil,
            body: body,
            documentation: Documentation(summary: summary, parameters: docs)
        )
    }
}
