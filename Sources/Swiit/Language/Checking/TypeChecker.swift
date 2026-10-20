import Foundation

/// A mistake in types, found before anything runs: the statement (or, in a
/// script, the whole script) doesn't run. See Docs/types.md.
struct TypeError: Error, CustomStringConvertible {
    let message: String
    /// The line of the statement it's in, when there's more than one.
    var line: Int?
    /// Where the statement it's in is, as far as that is known.
    var range: SourceRange?
    /// Where the expression it's in is, when that is known: narrower than the statement.
    var spot: SourceRange?
    /// A call's arguments don't line up with a signature's parameters, as
    /// opposed to lining up with a value of the wrong type.
    var isArity = false

    init(_ message: String) {
        self.message = message
    }

    var description: String { message }
}

/// Works out the type of every expression and checks it fits where it's
/// used, as Swift does: local, two-way inference, with every function's
/// signature written. Names already bound in the shell (from earlier
/// entries at the prompt, and the builtins) come from the shell; those the
/// program declares come from the program.
///
/// It also decides what the interpreter would otherwise decide as it runs,
/// and writes that into the program it returns: which overload a call
/// uses (`.chosen`). Commands, pipelines and builtins' results are
/// `unknown` until phase 3, which fits anywhere.
final class TypeChecker {
    struct Signature {
        var name: String
        var parameters: [Parameter]
        var returns: TypeAnnotation
        var isMutating = false
        var isThrowing = false
        /// `throws(E)`: the type of error it throws.
        var thrownType: TypeAnnotation?
        /// `rethrows`: a call throws if a closure passed to it does.
        var isRethrowing = false
        /// What it waits on: a call to an `async` one needs `await`.
        var effect: Effect = .sync
        /// Its position among the overloads the interpreter will have.
        var index = 0
        /// Its type parameters and the protocols each must conform to:
        /// `sorted<V: Comparable>(by:)`, and a sequence method's `Element`.
        var generics: [String: [String]] = [:]
        /// Of those, the ones its body names (`T()`, `x as? T`), which a call tells it the types of.
        var typeParameters: Set<String> = []
        /// What the type parameters were in the call this was matched to.
        var solved: [String: TypeAnnotation] = [:]
        /// Its result is flattened if it is an optional of an optional (see `Function.flattensResult`).
        var flattensResult = false
    
        init(name: String, parameters: [Parameter], returns: TypeAnnotation, isMutating: Bool = false, isThrowing: Bool = false, isRethrowing: Bool = false, effect: Effect = .sync, index: Int = 0, generics: [String: [String]] = [:]) {
            self.effect = effect
            self.name = name
            self.parameters = parameters
            self.returns = returns
            self.isMutating = isMutating
            self.isThrowing = isThrowing
            self.isRethrowing = isRethrowing
            self.index = index
            self.generics = generics
        }
    }

    enum Symbol {
        case protocolType(TypeProfile)
        case variable(TypeAnnotation, mutable: Bool)
        case functions([Signature])
        case structType(TypeProfile)
        case enumType(TypeProfile)
        /// A Swift type by name, bridged: `String`, `Int`.
        case swiftType(String)
        /// `async let x = …`: a `Task` the scope owns, whose value reading
        /// `x` awaits.
        case asyncLet(TypeAnnotation)
    }

    /// Where `return` goes: the declared result, or, for a closure that
    /// didn't say, the types its `return`s give.
    final class ReturnContext {
        let declared: TypeAnnotation?
        var seen: [TypeAnnotation] = []

        init(declared: TypeAnnotation?) {
            self.declared = declared
        }
    }

    /// Whether an error thrown here is handled: in a `throws` function, a
    /// closure, a `do` with a `catch`, or at the top level.
    struct ErrorContext {
        var handled: Bool
        /// What an error would have to leave, for messages.
        var boundary: Boundary = .topLevel
        /// The one type a `throws(E)` function throws, which a `throw` is checked against.
        var thrown: TypeAnnotation?

        enum Boundary {
            case topLevel, function(String), deferBlock

            /// Why an error can't get out, and what would let it.
            var unhandled: String {
                switch self {
                case .topLevel: "nothing catches it: use do/catch, try? or try!"
                case .function(let name): "\(name) isn't 'throws': mark it 'throws', or use do/catch, try? or try!"
                case .deferBlock: "nothing thrown can leave a defer: use do/catch, try? or try!"
                }
            }
        }
    
        init(handled: Bool, boundary: Boundary = .topLevel, thrown: TypeAnnotation? = nil) {
            self.handled = handled
            self.boundary = boundary
            self.thrown = thrown
        }
    }

    unowned let interpreter: Interpreter
    /// The type whose member was last looked up, so a JSON field can be
    /// written into a lookup that runs.
    var lastMemberBase: TypeAnnotation?

    /// What the program declares, innermost last, on top of the shell's names.
    var scopes: [[String: Symbol]] = [[:]]
    var returns: [ReturnContext] = []
    var errorContexts = [ErrorContext(handled: true)]
    /// The type of error the last call resolved throws, for the throwing site that follows it.
    var lastThrown: TypeAnnotation?
    /// What each throwing site seen throws: its type if the function it calls says (`throws(E)`), else nil (any Error).
    var thrownSeen: [TypeAnnotation?] = []
    /// Above zero while checking what a `try` covers.
    var tryDepth = 0
    /// Places that can throw, so far: how a `try` or a closure knows it
    /// covers one.
    var throwingSites = 0
    /// Above zero while checking what an `await` covers.
    var awaitDepth = 0
    /// Calls to `async` functions so far: how an `await` knows it covers one.
    var asyncSites = 0
    /// The effects of the top level, and of each function and closure being
    /// checked, innermost last (TypeChecker+Effects.swift).
    var effectContexts = [EffectContext(allowsAwait: true)]
    /// For each top-level function: the functions it calls without `await`.
    var topLevelUnawaited: [String: Set<String>] = [:]
    /// The functions the program being checked declares at its top level.
    var redeclaredHere: Set<String> = []
    var line: Int?
    /// Where the statement being checked is, when the program knows.
    var range: SourceRange?
    /// The expressions of the statement being checked, and where each was written.
    var spots: [Spot] = []
    /// What the extensions in the program being checked add, by type name.
    var localExtensions: [String: ExtensionLayer] = [:]

    init(interpreter: Interpreter) {
        self.interpreter = interpreter
    }

    /// Checks a program, returning it with what was decided written in.
    func check(_ program: Program) throws(TypeError) -> Program {
        var checked = program
        for statement in program.statements { if case .function(let decl) = statement { redeclaredHere.insert(decl.name) } }
        do {
            try checkBlock(&checked)
            recordUnawaitedCalls()
        } catch var error as TypeError {
            error.line = error.line ?? line
            error.range = error.range ?? range
            throw error
        } catch {
            preconditionFailure("the checker only throws TypeError")
        }
        return checked
    }

    /// The types of the globals a checked program declared, for the next
    /// entry at the prompt.
    var declaredGlobals: [String: TypeAnnotation] {
        scopes[0].compactMapValues { if case .variable(let type, _) = $0 { type } else { nil } }
    }
}
