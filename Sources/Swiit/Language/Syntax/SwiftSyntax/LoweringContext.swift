/// What a lowering knows at a point of the source: the names bound around it,
/// the struct whose body it is in, how many `try`s cover it, what a `return`
/// or `break` could leave. A layer's syntax holds Swift (a closure word, the
/// program in `$(…)`), and that is lowered on its own, from the source from there
/// on, in a lowering that starts knowing this (SwiftServices.swift).
/// What the declarations seen so far say, for the code that comes before or
/// after them: a class's place among the classes, a builder's name, which
/// enums are generic, which globals are computed.
struct DeclarationFacts {
    /// A class's superclass, as written.
    var superclass: [String: String] = [:]
    /// The instance variables and methods a class declares itself.
    var instanceMembers: [String: Set<String>] = [:]
    var resultBuilders: Set<String> = []
    var genericEnums: Set<String> = []
    var computedGlobals: Set<String> = []
}

struct LoweringContext {
    var bound: [String: NameKind] = [:]
    var declaredTypes: Set<String> = []
    var facts = DeclarationFacts()
    var locals: [Set<String>] = [[]]
    var members: [Set<String>] = []
    var staticContext: (owner: String, names: Set<String>)?
    var functions: Set<String> = []
    var tryDepth = 0
    var leaving = Leaving()
    /// The closures around, innermost last: whether each takes `$0`, `$1`, …
    var anonymous: [Bool] = []
}

extension Lowering {
    var context: LoweringContext {
        get {
            LoweringContext(bound: bound, declaredTypes: declaredTypes, facts: facts, locals: locals, members: members,
                            staticContext: staticContext, functions: functions, tryDepth: tryDepth, leaving: leaving,
                            anonymous: anonymous)
        }
        set {
            declaredTypes = newValue.declaredTypes
            facts = newValue.facts
            locals = newValue.locals
            members = newValue.members
            staticContext = newValue.staticContext
            functions = newValue.functions
            tryDepth = newValue.tryDepth
            leaving = newValue.leaving
            anonymous = newValue.anonymous
        }
    }
}
