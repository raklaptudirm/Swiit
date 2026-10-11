import Foundation
import SwishKit

/// Every function declared under one name. A name declared with `func` is
/// always bound to one of these, even with a single candidate.
@_spi(Host) public final class OverloadSet: Callable, @unchecked Sendable {
    @_spi(Host) public let name: String
    @_spi(Host) public let candidates: [Function]

    @_spi(Host) public init(name: String, candidates: [Function]) {
        self.name = name
        self.candidates = candidates
    }

    @_spi(Host) public var description: String {
        candidates.count == 1 ? candidates[0].description : "<func \(name) (\(candidates.count) overloads)>"
    }
}

extension Parameter {
    /// As a declaration writes it: `_ name: String`, `by key: Int`,
    /// `@input items: [Int]`, `paths: FilePath...`.
    @_spi(Host) public var declaration: [AttributedString] {
        var pieces: [AttributedString] = []
        if isInput { pieces += [.init("@input", .keyword), .init(" ")] }
        if label == name {
            pieces.append(.init(name, .variable))
        } else {
            pieces += [.init(label ?? "_", label == nil ? nil : .variable), .init(" "), .init(name, .variable)]
        }
        return pieces + [.init(": ")] + type.styled + (variadic ? [.init("...")] : [])
    }
}

extension Function {
    /// Like a Swift declaration: `greet(_ name: String, times: Int) -> String`,
    /// without the parameters `hiding` says, in pieces by what each is.
    @_spi(Host) public func declaration(
        as name: String? = nil, nameStyle: DisplayStyle = .command, hiding hidden: (Parameter) -> Bool
    ) -> [AttributedString] {
        var pieces: [AttributedString] = [.init(name ?? self.name ?? "closure", nameStyle), .init("(")]
        for (index, parameter) in parameters.filter({ !hidden($0) }).enumerated() {
            pieces += (index > 0 ? [.init(", ")] : []) + parameter.declaration
        }
        pieces.append(.init(")"))
        if let returnType, returnType != .void { pieces += [.init(" -> ")] + returnType.styled }
        return pieces
    }

    /// Like a Swift declaration: `greet(_ name: String, times: Int) -> String`.
    /// A Swift member's receiver, as a stage's input, isn't written.
    @_spi(Host) public var signature: String {
        AttributedString(joining: declaration { $0.isInput && $0.name == "self" }).text
    }

    @_spi(Host) public func declaration(hiding hidden: (Parameter) -> Bool) -> [AttributedString] {
        declaration(as: nil, nameStyle: .command, hiding: hidden)
    }
}

/// `\.size` or `\.status.code`: reads the path of members from a value.
/// Where a function is wanted it's one, as in Swift: `xs.map(\.name)`.
@_spi(Host) public final class KeyPathValue: Callable, @unchecked Sendable {
    @_spi(Host) public let path: [String]

    @_spi(Host) public init(path: [String]) {
        self.path = path
    }

    @_spi(Host) public var description: String { "\\." + path.joined(separator: ".") }

    @_spi(Host) public func read(from value: Value, in shell: Interpreter) throws -> Value {
        try path.reduce(value) { try shell.member($1, of: $0) }
    }
}

extension TypeAnnotation {
    @_spi(Host) public var isList: Bool {
        if case .list = self { true } else { false }
    }

    /// Whether a closure can be passed for it.
    @_spi(Host) public var acceptsFunction: Bool {
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
    @_spi(Host) public static func builtin(
        _ name: String, _ summary: String, _ parameters: [Parameter],
        docs: [String: String] = [:], _ body: FunctionBody
    ) -> Function {
        Function(
            name: name, parameters: parameters, returnType: nil, body: body,
            documentation: Documentation(summary: summary, parameters: docs)
        )
    }
}

extension Parameter {
    /// An argument by position.
    @_spi(Host) public static func positional(_ name: String, _ type: TypeAnnotation, default value: Value? = nil, variadic: Bool = false) -> Parameter {
        Parameter(label: nil, name: name, type: type, variadic: variadic, defaultValue: value.map(Expr.literal))
    }

    /// A labeled argument: a flag on the command line.
    @_spi(Host) public static func option(_ label: String, _ type: TypeAnnotation, default value: Value? = nil, short: Character? = nil) -> Parameter {
        Parameter(label: label, name: label, type: type, defaultValue: value.map(Expr.literal), shortFlag: short)
    }

    /// What's piped in.
    @_spi(Host) public static func input(_ name: String, _ type: TypeAnnotation) -> Parameter {
        Parameter(label: nil, name: name, type: type, isInput: true)
    }
}
