import Foundation
import Synchronization

// safe: every public method holds the interpreter's lock
/// The language: its scopes, what the checker remembers between entries, and the evaluator (the
/// `Interpreter+…` files). It reaches the outside world only through its `host`, and runs only
/// Swift. The host owns one.
public final class Interpreter: @unchecked Sendable {
    /// How this interpreter is run: where its output goes and how it is told to stop. A host may
    /// change it between runs.
    public var host: Interpreter.Host

    /// What runs this interpreter, if it is more than an embedder's call: the
    /// host, whose nodes reach it from here. Weak, as the owner holds the
    /// interpreter.
    weak var owner: AnyObject?
    /// The members, by name, of the host's object types that Swift doesn't
    /// declare (the host's `Job`), for the checker.
    /// What `await` waits for, if the host has anything to wait for.

    /// The task running now: its call stack and cancellation (TaskContext.swift).
    @exclusivity(unchecked) var task: TaskContext
    /// The first task: the host's own (the host's prompt, an embedder's `eval`).
    let mainTask = TaskContext(globals: [Scope(), Scope()])
    /// What Swiit code runs under, one task at a time (InterpreterLock.swift).
    let lock = InterpreterLock()
    /// Tasks started and not yet ended.
    var runningTasks = 0
    /// The types programs have declared, by reference, including those a later declaration of the same
    /// name has since hidden.
    var declaredTypes: [TypeRef: any DeclaredType] = [:]
    /// The module a program's types are in, shown before their names where Swift shows it
    /// (`main.Point`).
    var moduleName = "main"
    /// What each enum a program declares keeps beside its cases, by the enum's identity.
    var enumTypes: [ObjectIdentifier: EnumType] = [:]
    /// The operators and precedence groups declared at the prompt, by what they declare, as source.
    var declaredOperators: [String: String] = [:]
    /// Instances released since a statement began, whose `deinit` runs at the next one.
    let pendingDeinits = Mutex<[ClassInstance]>([])
    // safe: a hint, set holding `pendingDeinits`; a stale read only delays a `deinit` by a statement
    nonisolated(unsafe) var hasPendingDeinits = false
    /// The Swift types scripts can use, by the name they are written with: the core's, and those
    /// this interpreter's host has registered. Another interpreter's registrations are not here.
    var bridged: [String: ImplementedType] = Bridge.core

    /// Whether a call has bound a type argument yet. Until one has, no scope holds one, and a
    /// type parameter is conformed to without looking for it.
    var hasBoundTypeArguments = false

    /// What extensions add to a type, by the type's name (`Int`, `Array`, a struct's).
    var typeExtensions: [String: TypeMembers] = [:]
    /// Methods every sequence has, like `sorted` and `filter`.
    var sequenceMethods: [String: OverloadSet] = [:]
    /// What the checker remembers from entries already checked.
    var checkerMemory = CheckerMemory()
    /// What reads source into the tree: SwiftParser's, lowered, unless given another.
    var frontEnd: any SyntaxFrontEnd = SwiftSyntaxFrontEnd()
    /// The file being run, for `#filePath`; nil at the prompt.
    /// The script being run, as errors and `#filePath` name it.
    public var file: String?
    /// Told each simple statement as it finishes, for a host that keeps an
    /// exit status, as the host does.
    /// Whether the host is told as statements finish; not while a `defer` cleans up.
    var observesStatements = true
    /// How function bodies run: on the tree evaluator, or compiled for the VM where the compiler can.
    var engine = Engine.initial
    /// The functions the VM's compiler left to the tree evaluator, each with why, as they were met.
    var vmFallbacks: [String] = []
    /// How many loops of a program's own code the VM has run, which a test counts on.
    var vmLoops = 0
    /// How many times the VM has been entered from outside it: a call from the tree evaluator, from a
    /// native body or from the host. A call the loop makes itself is not one, and a task whose Swift
    /// stack holds only the loop is one that could be parked (`Docs/vm.md`).
    var vmEntries = 0
    /// Calls the loop handed to the tree evaluator, by what they were (a test counts them).
    var vmSlowCalls: [String: Int] = [:]
    /// How many pieces of compiled code the tree evaluator has run, which are those the loop's fast
    /// paths left to it (a test counts them).
    var vmTreeRuns = 0
    /// How many calls of closures that only compute a native body made were run by `runLeaf`.
    var vmLeafCalls = 0

    /// What bounds a run (steps, depth, time, output) unless the run is given limits of its own.
    var limits = Interpreter.Limits()
    /// What the host's output and error have written, which a run measures against
    /// `limits.maxOutputBytes` from where it began.
    let outputCounter: OutputCounter
    /// How to ask each run in progress to stop, from any thread (`cancel()`).
    let activeRuns = Mutex<[Cancellation]>([])

    init(host: Interpreter.Host, outputCounter: OutputCounter) {
        self.host = host
        self.outputCounter = outputCounter
        self.task = mainTask
    }
}

extension Interpreter {
    /// The reference each type the program being checked or run declares at its top level will have,
    /// by name: the symbols that name one share it, as they cannot share a declaration that does not
    /// exist yet, and the declaration takes it when it runs. Belongs to the run, as a type's name can
    /// be another's in a run alongside.
    var reservedRefs: [String: TypeRef] {
        get { task.run.reservedRefs }
        set { task.run.reservedRefs = newValue }
    }

    /// The references to reserve for a program: one for each struct, class, enum and protocol it
    /// declares at its top level.
    func reservations(for program: Program) -> [String: TypeRef] {
        var reserved: [String: TypeRef] = [:]
        for statement in program.statements {
            switch statement {
            case .structDecl(let decl): reserved[decl.name] = .declare(decl.name)
            case .classDecl(let decl): reserved[decl.name] = .declare(decl.name)
            case .enumDecl(let decl): reserved[decl.name] = .declare(decl.name)
            case .protocolDecl(let decl): reserved[decl.name] = .declare(decl.name)
            default: continue
            }
        }
        return reserved
    }

    /// The reference a declaration of this name has: the one reserved for it, which it takes, or a
    /// new one.
    func takeReservedRef(_ name: String) -> TypeRef {
        reservedRefs.removeValue(forKey: name) ?? .declare(name)
    }

    /// Reports an error, to wherever standard error is redirected.
    func report(_ message: String) {
        // Bold red, as a terminal writes it, when the stream is styled.
        let styled = host.error.traits().isStyled
        func red(_ text: String) -> String { styled ? "\u{1B}[1;31m\(text)\u{1B}[0m" : text }
        if message.hasPrefix("error: ") {
            host.error.write(red("\(host.name): error:") + message.dropFirst(6) + "\n")
        } else {
            host.error.write(red("\(host.name):") + " \(message)\n")
        }
    }
}

extension Interpreter {
    /// Parses a program, knowing the names already declared.
    func parse(_ source: String) -> Result<Program, SyntaxError> {
        do {
            return .success(try frontEnd.parse(source, bound: globalNames()))
        } catch let error as SyntaxError {
            return .failure(error)
        } catch {
            return .failure(SyntaxError("\(error)"))
        }
    }

    /// Names the parser should know: builtins and globals, as variables or functions.
    func globalNames() -> [String: NameKind] {
        scopes[0].bindings.merging(scopes[1].bindings) { $1 }
            .mapValues { binding in
                if binding.isFunction { return .function }
                if binding.isComputed { return .variable }
                if case .object(is any DeclaredType) = binding.value.storage { return .type }
                if case .object(is NativeTypeName) = binding.value.storage { return .type }
                return .variable
            }
            .merging(declaredOperators.mapValues(NameKind.operatorDeclaration)) { $1 }
    }
}
