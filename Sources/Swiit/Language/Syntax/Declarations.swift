import Foundation
import SwishKit

@_spi(Shell) public struct FunctionDecl: Equatable, Sendable {
    @_spi(Shell) public var name: String
    @_spi(Shell) public var parameters: [Parameter]
    @_spi(Shell) public var returnType: TypeAnnotation?
    @_spi(Shell) public var body: Program
    @_spi(Shell) public var documentation: Documentation?
    /// A struct's `mutating func`, which may change `self`.
    @_spi(Shell) public var isMutating = false
    /// `throws`: calling it needs `try`.
    @_spi(Shell) public var isThrowing = false
    /// `rethrows`: it throws only if a closure passed to it does.
    @_spi(Shell) public var isRethrowing = false
    /// `<T, V: Comparable>` and `where` clauses: each type parameter, and
    /// the protocols it must conform to. Only the prelude has these, for now.
    @_spi(Shell) public var generics: [String: [String]] = [:]
    @_spi(Shell) public var names = NamesUsed()

    @_spi(Shell) public init(name: String, parameters: [Parameter], returnType: TypeAnnotation? = nil, body: Program, documentation: Documentation? = nil, isMutating: Bool = false, isThrowing: Bool = false, isRethrowing: Bool = false, generics: [String: [String]] = [:], names: NamesUsed = NamesUsed()) {
        self.name = name
        self.parameters = parameters
        self.returnType = returnType
        self.body = body
        self.documentation = documentation
        self.isMutating = isMutating
        self.isThrowing = isThrowing
        self.isRethrowing = isRethrowing
        self.generics = generics
        self.names = names
    }
}

/// Assigning to a variable, or to part of one: `p.x`, `xs[0]`, `r["k"]`.
@_spi(Shell) public struct Assignment: Equatable, Sendable {
    @_spi(Shell) public enum Step: Equatable, Sendable {
        case member(String)
        case index(Expr)
    }

    @_spi(Shell) public var root: String
    @_spi(Shell) public var path: [Step] = []
    /// `+=` and the like: the operator applied to the current value.
    @_spi(Shell) public var op: BinaryOperator?
    @_spi(Shell) public var value: Expr

    @_spi(Shell) public init(root: String, path: [Step] = [], op: BinaryOperator? = nil, value: Expr) {
        self.root = root
        self.path = path
        self.op = op
        self.value = value
    }
}

/// `struct Name { var x: Int; func f() {…}; init(…) {…} }`.
@_spi(Shell) public struct StructDecl: Equatable, Sendable {
    @_spi(Shell) public var name: String
    @_spi(Shell) public var properties: [PropertyDecl]
    @_spi(Shell) public var methods: [FunctionDecl]
    @_spi(Shell) public var initializers: [FunctionDecl]
    /// `struct Point: Equatable, Hashable`.
    @_spi(Shell) public var conformances: [String] = []
    /// `static let origin = Point(x: 0, y: 0)`: values of the type itself,
    /// and `static func`s, which are called on it: `Point.origin`.
    @_spi(Shell) public var staticProperties: [PropertyDecl] = []
    @_spi(Shell) public var staticMethods: [FunctionDecl] = []

    @_spi(Shell) public init(name: String, properties: [PropertyDecl], methods: [FunctionDecl], initializers: [FunctionDecl], conformances: [String] = []) {
        self.name = name
        self.properties = properties
        self.methods = methods
        self.initializers = initializers
        self.conformances = conformances
    }
}

@_spi(Shell) public struct PropertyDecl: Equatable, Sendable {
    @_spi(Shell) public var name: String
    @_spi(Shell) public var mutable: Bool
    @_spi(Shell) public var type: TypeAnnotation? = nil
    @_spi(Shell) public var defaultValue: Expr? = nil
    /// A computed property's body; nil for a stored one.
    @_spi(Shell) public var getter: Program? = nil
    @_spi(Shell) public var getterNames = NamesUsed()

    @_spi(Shell) public init(name: String, mutable: Bool, type: TypeAnnotation? = nil, defaultValue: Expr? = nil, getter: Program? = nil, getterNames: NamesUsed = NamesUsed()) {
        self.name = name
        self.mutable = mutable
        self.type = type
        self.defaultValue = defaultValue
        self.getter = getter
        self.getterNames = getterNames
    }
}

/// The `#` comment block directly above a `func`, for `--help`.
@_spi(Shell) public struct Documentation: Equatable, Sendable {
    @_spi(Shell) public var summary: String
    /// From `- Parameter name: description` lines.
    @_spi(Shell) public var parameters: [String: String]

    @_spi(Shell) public init(summary: String, parameters: [String: String]) {
        self.summary = summary
        self.parameters = parameters
    }
}

@_spi(Shell) public struct ClosureLiteral: Equatable, Sendable {
    /// For `{ $0 * 2 }`, the implicit `$0`, `$1`, … parameters.
    @_spi(Shell) public var parameters: [Parameter]
    @_spi(Shell) public var returnType: TypeAnnotation?
    @_spi(Shell) public var body: Program
    @_spi(Shell) public var names = NamesUsed()

    @_spi(Shell) public init(parameters: [Parameter], returnType: TypeAnnotation? = nil, body: Program, names: NamesUsed = NamesUsed()) {
        self.parameters = parameters
        self.returnType = returnType
        self.body = body
        self.names = names
    }
}

/// The names a body mentions, so a closure keeps only the variables it
/// uses rather than every scope around it (which would keep the scope it's
/// stored in, and leak). Not part of what the code says, so it doesn't
/// count toward equality.
@_spi(Shell) public struct NamesUsed: Equatable, Sendable {
    @_spi(Shell) public var names: Set<String> = []

    @_spi(Shell) public static func == (lhs: NamesUsed, rhs: NamesUsed) -> Bool { true }

    @_spi(Shell) public init(names: Set<String> = []) {
        self.names = names
    }
}

@_spi(Shell) public struct Parameter: Equatable, Sendable {
    /// The argument label; nil for `_` (positional in command mode).
    @_spi(Shell) public var label: String?
    @_spi(Shell) public var name: String
    @_spi(Shell) public var type: TypeAnnotation = .any
    @_spi(Shell) public var variadic = false
    @_spi(Shell) public var defaultValue: Expr?
    /// `@input`: receives pipeline input; per item, or the whole stream
    /// if its type is a list.
    @_spi(Shell) public var isInput = false
    /// `@flag("n")`: a short flag in command mode.
    @_spi(Shell) public var shortFlag: Character?
    /// A plugin's default only Swift can compute, like `Date()`: the
    /// argument is left out for the plugin to fill in. Its source, for help.
    @_spi(Shell) public var externalDefault: String?

    @_spi(Shell) public var hasDefault: Bool { defaultValue != nil || externalDefault != nil }

    @_spi(Shell) public init(
        label: String? = nil, name: String, type: TypeAnnotation = .any, variadic: Bool = false,
        defaultValue: Expr? = nil, isInput: Bool = false, shortFlag: Character? = nil, externalDefault: String? = nil
    ) {
        self.label = label
        self.name = name
        self.type = type
        self.variadic = variadic
        self.defaultValue = defaultValue
        self.isInput = isInput
        self.shortFlag = shortFlag
        self.externalDefault = externalDefault
    }
}
