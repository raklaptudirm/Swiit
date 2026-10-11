import Foundation
import SwiitKit

@_spi(Layer) public struct FunctionDecl: Equatable, Sendable {
    @_spi(Layer) public var name: String
    @_spi(Layer) public var parameters: [Parameter]
    @_spi(Layer) public var returnType: TypeAnnotation?
    @_spi(Layer) public var body: Program
    @_spi(Layer) public var documentation: Documentation?
    /// A struct's `mutating func`, which may change `self`.
    @_spi(Layer) public var isMutating = false
    /// `throws`: calling it needs `try`.
    @_spi(Layer) public var isThrowing = false
    /// Declared `async`.
    @_spi(Swiit) public var isAsync = false
    /// `async` if declared so.
    @_spi(Layer) public var effect: Effect = .sync
    /// `rethrows`: it throws only if a closure passed to it does.
    @_spi(Layer) public var isRethrowing = false
    /// `<T, V: Comparable>` and `where` clauses: each type parameter, and
    /// the protocols it must conform to. Only the prelude has these, for now.
    @_spi(Layer) public var generics: [String: [String]] = [:]
    @_spi(Layer) public var names = NamesUsed()

    @_spi(Layer) public init(name: String, parameters: [Parameter], returnType: TypeAnnotation? = nil, body: Program, documentation: Documentation? = nil, isMutating: Bool = false, isThrowing: Bool = false, isAsync: Bool = false, isRethrowing: Bool = false, generics: [String: [String]] = [:], names: NamesUsed = NamesUsed()) {
        self.name = name
        self.parameters = parameters
        self.returnType = returnType
        self.body = body
        self.documentation = documentation
        self.isMutating = isMutating
        self.isThrowing = isThrowing
        self.isAsync = isAsync
        self.effect = isAsync ? .async : .sync
        self.isRethrowing = isRethrowing
        self.generics = generics
        self.names = names
    }
}

/// Assigning to a variable, or to part of one: `p.x`, `xs[0]`, `r["k"]`.
@_spi(Layer) public struct Assignment: Equatable, Sendable {
    @_spi(Layer) public enum Step: Equatable, Sendable {
        case member(String)
        case index(Expr)
    }

    @_spi(Layer) public var root: String
    @_spi(Layer) public var path: [Step] = []
    /// `+=` and the like: the operator applied to the current value.
    @_spi(Swiit) public var op: BinaryOperator?
    @_spi(Layer) public var value: Expr

    @_spi(Layer) public init(root: String, path: [Step] = [], op: BinaryOperator? = nil, value: Expr) {
        self.root = root
        self.path = path
        self.op = op
        self.value = value
    }
}

/// `struct Name { var x: Int; func f() {…}; init(…) {…} }`.
@_spi(Layer) public struct StructDecl: Equatable, Sendable {
    @_spi(Layer) public var name: String
    @_spi(Layer) public var properties: [PropertyDecl]
    @_spi(Layer) public var methods: [FunctionDecl]
    @_spi(Swiit) public var initializers: [FunctionDecl]
    /// `struct Point: Equatable, Hashable`.
    @_spi(Layer) public var conformances: [String] = []
    /// `static let origin = Point(x: 0, y: 0)`: values of the type itself,
    /// and `static func`s, which are called on it: `Point.origin`.
    @_spi(Swiit) public var staticProperties: [PropertyDecl] = []
    @_spi(Swiit) public var staticMethods: [FunctionDecl] = []

    @_spi(Layer) public init(name: String, properties: [PropertyDecl], methods: [FunctionDecl], initializers: [FunctionDecl], conformances: [String] = []) {
        self.name = name
        self.properties = properties
        self.methods = methods
        self.initializers = initializers
        self.conformances = conformances
    }
}

@_spi(Layer) public struct PropertyDecl: Equatable, Sendable {
    @_spi(Layer) public var name: String
    @_spi(Layer) public var mutable: Bool
    @_spi(Layer) public var type: TypeAnnotation? = nil
    @_spi(Layer) public var defaultValue: Expr? = nil
    /// A computed property's body; nil for a stored one.
    @_spi(Swiit) public var getter: Program? = nil
    @_spi(Swiit) public var getterNames = NamesUsed()

    @_spi(Layer) public init(name: String, mutable: Bool, type: TypeAnnotation? = nil, defaultValue: Expr? = nil, getter: Program? = nil, getterNames: NamesUsed = NamesUsed()) {
        self.name = name
        self.mutable = mutable
        self.type = type
        self.defaultValue = defaultValue
        self.getter = getter
        self.getterNames = getterNames
    }
}

/// The `#` comment block directly above a `func`, for `--help`.
@_spi(Layer) public struct Documentation: Equatable, Sendable {
    @_spi(Layer) public var summary: String
    /// From `- Parameter name: description` lines.
    @_spi(Layer) public var parameters: [String: String]

    @_spi(Layer) public init(summary: String, parameters: [String: String]) {
        self.summary = summary
        self.parameters = parameters
    }
}

@_spi(Layer) public struct ClosureLiteral: Equatable, Sendable {
    /// For `{ $0 * 2 }`, the implicit `$0`, `$1`, … parameters.
    @_spi(Layer) public var parameters: [Parameter]
    @_spi(Layer) public var returnType: TypeAnnotation?
    @_spi(Layer) public var body: Program
    @_spi(Layer) public var names = NamesUsed()

    @_spi(Layer) public init(parameters: [Parameter], returnType: TypeAnnotation? = nil, body: Program, names: NamesUsed = NamesUsed()) {
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
@_spi(Layer) public struct NamesUsed: Equatable, Sendable {
    @_spi(Layer) public var names: Set<String> = []

    @_spi(Layer) public static func == (lhs: NamesUsed, rhs: NamesUsed) -> Bool { true }

    @_spi(Layer) public init(names: Set<String> = []) {
        self.names = names
    }
}

@_spi(Layer) public struct Parameter: Equatable, Sendable {
    /// The argument label; nil for `_` (positional in command mode).
    @_spi(Layer) public var label: String?
    @_spi(Layer) public var name: String
    @_spi(Layer) public var type: TypeAnnotation = .any
    @_spi(Layer) public var variadic = false
    @_spi(Layer) public var defaultValue: Expr?
    /// `@input`: receives pipeline input; per item, or the whole stream
    /// if its type is a list.
    @_spi(Layer) public var isInput = false
    /// `@flag("n")`: a short flag in command mode.
    @_spi(Layer) public var shortFlag: Character?
    /// A plugin's default only Swift can compute, like `Date()`: the
    /// argument is left out for the plugin to fill in. Its source, for help.
    @_spi(Layer) public var externalDefault: String?

    @_spi(Layer) public var hasDefault: Bool { defaultValue != nil || externalDefault != nil }

    @_spi(Layer) public init(
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
