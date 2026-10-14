import Foundation
import SwiitKit

extension Parameter {
    func withBuilder(_ builder: String?) -> Parameter {
        var copy = self
        copy.resultBuilder = builder
        return copy
    }
}

extension FunctionDecl {
    func withBuilder(_ builder: String?) -> FunctionDecl {
        var copy = self
        copy.resultBuilder = builder
        return copy
    }

    func withThrown(_ type: TypeAnnotation?) -> FunctionDecl {
        var copy = self
        copy.thrownType = type
        return copy
    }

    func withModifiers(override: Bool, nonisolated: Bool) -> FunctionDecl {
        var copy = self
        copy.isOverride = override
        copy.isNonisolated = nonisolated
        return copy
    }
}

@_spi(Layer) public struct FunctionDecl: Equatable, Sendable {
    @_spi(Layer) public var name: String
    @_spi(Layer) public var parameters: [Parameter]
    var returnType: TypeAnnotation?
    var body: Program
    @_spi(Layer) public var documentation: Documentation?
    /// A struct's `mutating func`, which may change `self`.
    @_spi(Layer) public var isMutating = false
    /// `throws`: calling it needs `try`.
    @_spi(Layer) public var isThrowing = false
    /// `throws(E)`: the one type of error it throws.
    @_spi(Layer) public var thrownType: TypeAnnotation?
    /// Declared `async`.
    var isAsync = false
    /// `async` if declared so.
    var effect: Effect = .sync
    /// `rethrows`: it throws only if a closure passed to it does.
    var isRethrowing = false
    /// `init?`: `return nil` leaves nothing made.
    var isFailable = false
    /// `override func`: replaces a superclass's.
    var isOverride = false
    /// `@Builder func …`: its body is made by the result builder's `buildBlock`.
    @_spi(Layer) public var resultBuilder: String?
    /// `nonisolated`: an actor's member reached without `await`.
    var isNonisolated = false
    /// `convenience init`: makes the value through another initializer.
    var isConvenience = false
    /// `<T, V: Comparable>` and `where` clauses: each type parameter, and
    /// the protocols it must conform to. Only the prelude has these, for now.
    @_spi(Layer) public var generics: [String: [String]] = [:]
    var names = NamesUsed()

    init(name: String, parameters: [Parameter], returnType: TypeAnnotation? = nil, body: Program, documentation: Documentation? = nil, isMutating: Bool = false, isThrowing: Bool = false, isAsync: Bool = false, isRethrowing: Bool = false, generics: [String: [String]] = [:], names: NamesUsed = NamesUsed()) {
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
    enum Step: Equatable, Sendable {
        case member(String)
        case index(Expr)
        /// `counts[word, default: 0] += 1`: a dictionary's entry, or the default if it has none.
        case indexDefault(Expr, Expr)
        /// A subscript with several or labeled arguments.
        case subscripted([Argument])
        /// `x!`: through an optional, which must hold a value.
        case unwrap
        /// `x?.p = v`, `x? += 1`: nothing happens if `x` is nil.
        case optionalChain
    }

    var root: String
    var path: [Step] = []
    /// `+=` and the like: the operator applied to the current value.
    var op: BinaryOperator?
    @_spi(Layer) public var value: Expr

    init(root: String, path: [Step] = [], op: BinaryOperator? = nil, value: Expr) {
        self.root = root
        self.path = path
        self.op = op
        self.value = value
    }
}

/// `struct Name { var x: Int; func f() {…}; init(…) {…} }`.
@_spi(Layer) public struct StructDecl: Equatable, Sendable {
    @_spi(Layer) public var name: String
    var properties: [PropertyDecl]
    @_spi(Layer) public var methods: [FunctionDecl]
    var initializers: [FunctionDecl]
    /// `struct Point: Equatable, Hashable`.
    var conformances: [String] = []
    /// `static let origin = Point(x: 0, y: 0)`: values of the type itself,
    /// and `static func`s, which are called on it: `Point.origin`.
    var staticProperties: [PropertyDecl] = []
    var staticMethods: [FunctionDecl] = []
    /// `subscript(i: Int) -> T { get … set … }`: what `value[i]` reads and writes.
    var subscripts: [SubscriptDecl] = []

    init(name: String, properties: [PropertyDecl], methods: [FunctionDecl], initializers: [FunctionDecl], conformances: [String] = []) {
        self.name = name
        self.properties = properties
        self.methods = methods
        self.initializers = initializers
        self.conformances = conformances
    }
}

/// `class Dog: Animal, Named { … }`, and `actor Counter { … }`: reference types, whose
/// instances are shared, with inheritance.
@_spi(Layer) public struct ClassDecl: Equatable, Sendable {
    @_spi(Layer) public var name: String
    /// What follows the colon: the superclass first if there is one, then protocols.
    var inherited: [String]
    /// Its properties, methods, initializers, subscripts and static members, as a struct has them.
    var members: StructDecl
    /// `deinit { … }`: runs when the last reference to an instance is gone.
    var deinitializer: Program?
    var deinitializerNames = NamesUsed()
    /// `actor`: its members are reached from outside with `await`.
    var isActor = false
}

/// `protocol Shape { var area: Double { get }; func scaled(by k: Double) -> Self }`: what a
/// type has to have to conform, and the protocols it takes in (`protocol A: B`).
@_spi(Layer) public struct ProtocolDecl: Equatable, Sendable {
    @_spi(Layer) public var name: String
    var inherited: [String] = []
    var methods: [FunctionDecl] = []
    var properties: [ProtocolProperty] = []
    var staticMethods: [FunctionDecl] = []
    var staticProperties: [ProtocolProperty] = []
    var initializers: [FunctionDecl] = []
    /// `associatedtype Item`: a type the conforming type chooses.
    var associatedTypes: [String] = []
}

/// `var area: Double { get }`, `var name: String { get set }`.
struct ProtocolProperty: Equatable, Sendable {
    var name: String
    var type: TypeAnnotation
    var settable: Bool
}

/// `extension Int { var squared: Int { … } }`: members added to a type declared
/// elsewhere (a struct, an enum, or one of Swift's), and protocols it conforms to.
@_spi(Layer) public struct ExtensionDecl: Equatable, Sendable {
    /// The type as written: `Int`, `Array`, `Outer.Inner`.
    var typeName: String
    /// Its members, in the shape a struct's are; the name is the type's.
    var members: StructDecl
    var conformances: [String]
}

/// `subscript(row: Int, column: Int) -> Double { get { … } set { … } }`.
struct SubscriptDecl: Equatable, Sendable {
    var parameters: [Parameter]
    var returnType: TypeAnnotation
    var getter: Program
    var getterNames = NamesUsed()
    var setter: Program?
    var setterName = "newValue"
    var setterNames = NamesUsed()
}

@_spi(Layer) public struct PropertyDecl: Equatable, Sendable {
    @_spi(Layer) public var name: String
    var mutable: Bool
    @_spi(Layer) public var type: TypeAnnotation?
    @_spi(Layer) public var defaultValue: Expr?
    /// A computed property's body; nil for a stored one.
    var getter: Program?
    var getterNames = NamesUsed()
    /// `set { … }` of a computed property, with the name its value goes by.
    var setter: Program?
    var setterName = "newValue"
    var setterNames = NamesUsed()
    /// `weak var parent: Node?`: the value is held without keeping it alive.
    var isWeak = false
    /// `lazy var`: its value is worked out when it is first read, which may use `self`.
    var isLazy = false
    /// `override var`: replaces a superclass's property.
    var isOverride = false
    var isNonisolated = false
    /// `willSet` and `didSet` of a stored property: run before and after it changes.
    var willSet: Program?
    var willSetName = "newValue"
    var willSetNames = NamesUsed()
    var didSet: Program?
    var didSetName = "oldValue"
    var didSetNames = NamesUsed()

    init(name: String, mutable: Bool, type: TypeAnnotation? = nil, defaultValue: Expr? = nil, getter: Program? = nil, getterNames: NamesUsed = NamesUsed()) {
        self.name = name
        self.mutable = mutable
        self.type = type
        self.defaultValue = defaultValue
        self.getter = getter
        self.getterNames = getterNames
    }
}

/// The `#` comment block directly above a `func`, for `--help`.
public struct Documentation: Equatable, Sendable {
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
    var returnType: TypeAnnotation?
    var body: Program
    var names = NamesUsed()
    /// The result builder whose `buildBlock` the body was made into, once it has been.
    var builtBy: String?
    /// `[weak self, count]`: values taken when the closure is made.
    @_spi(Layer) public var captures: [Capture] = []

    @_spi(Layer) public struct Capture: Equatable, Sendable {
        @_spi(Layer) public var name: String
        @_spi(Layer) public var value: Expr
        /// `weak` makes it optional, nil once the instance is gone; `unowned` holds it as it is.
        @_spi(Layer) public var isWeak: Bool
        /// `unowned`: not kept alive by the closure either, but not an optional.
        @_spi(Layer) public var isUnowned = false
    }

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
    var names: Set<String> = []

    @_spi(Layer) public static func == (lhs: NamesUsed, rhs: NamesUsed) -> Bool { true }

    @_spi(Layer) public init(names: Set<String> = []) {
        self.names = names
    }
}

public struct Parameter: Equatable, Sendable {
    /// The argument label; nil for `_` (positional in command mode).
    @_spi(Layer) public var label: String?
    @_spi(Layer) public var name: String
    @_spi(Layer) public var type: TypeAnnotation = .any
    @_spi(Layer) public var variadic = false
    @_spi(Layer) public var defaultValue: Expr?
    /// `@input`: receives pipeline input; per item, or the whole stream
    /// if its type is a list.
    @_spi(Layer) public var isInput = false
    /// `@Builder content: () -> V`: a closure given for it is made by the result builder.
    @_spi(Layer) public var resultBuilder: String?
    /// `@flag("n")`: a short flag in command mode.
    @_spi(Layer) public var shortFlag: Character?
    /// `inout`: the argument is passed as `&place`, and the place gets the
    /// parameter's value back when the function ends.
    var isInout = false
    /// `@autoclosure () -> T`: the argument is written as a T, and made a closure.
    @_spi(Layer) public var isAutoclosure = false
    /// A default only Swift can compute, like `Date()`: the
    /// argument is left out for the Swift function to fill in. Its source, for help.
    @_spi(Layer) public var externalDefault: String?

    @_spi(Layer) public var hasDefault: Bool { defaultValue != nil || externalDefault != nil }

    @_spi(Layer) public init(
        label: String? = nil, name: String, type: TypeAnnotation = .any, variadic: Bool = false,
        defaultValue: Expr? = nil, isInput: Bool = false, shortFlag: Character? = nil, externalDefault: String? = nil,
        isInout: Bool = false, isAutoclosure: Bool = false
    ) {
        self.isAutoclosure = isAutoclosure
        self.isInout = isInout
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
