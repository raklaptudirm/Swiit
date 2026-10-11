/// What a lowering knows at a point of the source: the names bound around it,
/// the struct whose body it is in, how many `try`s cover it, what a `return`
/// or `break` could leave. A layer's syntax holds Swift (a closure word, the
/// program in `$(…)`), and that is lowered on its own, from the source from there
/// on, in a lowering that starts knowing this (SwiftServices.swift).
struct LoweringContext {
    var bound: [String: NameKind] = [:]
    var declaredTypes: Set<String> = []
    var locals: [Set<String>] = [[]]
    var members: [Set<String>] = []
    var staticContext: (owner: String, names: Set<String>)?
    var functions: Set<String> = []
    var tryDepth = 0
    var leaving = Leaving()
    /// The closures around, innermost last: whether each takes `$0`, `$1`, …
    var anonymous: [Bool] = []
    var sawImport = false
}

extension Lowering {
    var context: LoweringContext {
        get {
            LoweringContext(bound: bound, declaredTypes: declaredTypes, locals: locals, members: members,
                            staticContext: staticContext, functions: functions, tryDepth: tryDepth, leaving: leaving,
                            anonymous: anonymous, sawImport: sawImport)
        }
        set {
            declaredTypes = newValue.declaredTypes
            locals = newValue.locals
            members = newValue.members
            staticContext = newValue.staticContext
            functions = newValue.functions
            tryDepth = newValue.tryDepth
            leaving = newValue.leaving
            anonymous = newValue.anonymous
            sawImport = newValue.sawImport
        }
    }
}
