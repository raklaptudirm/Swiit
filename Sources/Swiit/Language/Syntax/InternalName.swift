// Names the lowering and the runtime use between them. Each begins with `$`, which no name a program writes does (a `$0` is
// a closure's argument, and `$name` is host syntax, refused in Swift-only code), so they never collide with its own.
// Kept here so that each is spelled once: a misspelling in either place would otherwise find nothing, and say nothing.

enum InternalName {
    /// `weak var x`: the function that makes the reference.
    static let weak = "$weak"
    /// `Optional(x)`: x, as an optional.
    static let some = "$some"
    /// `o?.a.b`: the rest of the chain, run on `o` if it has a value, as an optional.
    static let chain = "$chain"
    /// `let x: Int`, given its value later: a variable declared without a value.
    static let uninitialized = "$uninitialized"
    /// Bound while an initializer's body is checked, so it may set the properties of `self` it is making.
    static let initializing = "$initializing"
    /// A type argument bound in a scope, `$type T`, for the body of a generic function that names it.
    static let typeArgumentPrefix = "$type "
    /// `for case let x? in xs`: the loop's element, which the pattern is matched against in the body.
    static let item = "$item"

    /// A computed global `name`: reads and writes of it are calls of functions of these names.
    static func getter(_ name: String) -> String { "$get_" + name }
    static func setter(_ name: String) -> String { "$set_" + name }
    /// `var x: T? { didSet { … } }`: the variable of its own that the observed property is stored in.
    static func stored(_ name: String) -> String { "$stored_" + name }
    /// The value the `n`th destructuring declaration being lowered takes apart.
    static func tuple(_ n: Int) -> String { "$tuple\(n)" }
    /// The unwrapped value of the `n`th optional chain being lowered.
    static func chainValue(_ n: Int) -> String { "$chain\(n)" }
}
