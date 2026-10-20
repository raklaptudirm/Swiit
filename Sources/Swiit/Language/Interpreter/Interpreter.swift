import Foundation

/// The language: its scopes, what the checker remembers between entries, and
/// the evaluator (the `Interpreter+…` files). It knows nothing of the
/// terminal, processes or jobs: it reaches the world through its `host`, and
/// runs only Swift (a layer over it, like the shell, rewrites its own syntax
/// first; Docs/boundaries.md). The shell owns one.
public final class Interpreter: @unchecked Sendable { // safe: every public method holds the interpreter's lock
    /// How this interpreter is run: where its output goes, how to tell it to stop.
    /// Where its output goes and how it is told to stop; a host may change it between runs.
    public var host: Interpreter.Host

    /// What runs this interpreter, if it is more than an embedder's call: the
    /// shell, whose nodes reach it from here. Weak, as the owner holds the
    /// interpreter.
    weak var owner: AnyObject?
    /// The members, by name, of the host's object types that Swift doesn't
    /// declare (the shell's `Job`), for the checker.
    /// The bridged libraries installed: the core's, and the host's.
    var libraries: [Library] = []
    /// The types of dynamic objects' members (`DynamicObject`), by type name.
    var dynamicTypes: [String: DynamicType] = [:]
    /// What `await` waits for, if the host has anything to wait for.
    var awaiting: Awaiting?

    /// The task running now: its call stack and cancellation (TaskContext.swift).
    var task: TaskContext
    /// The first task: the host's own (the shell's prompt, an embedder's `eval`).
    let mainTask = TaskContext(globals: [Scope(), Scope()])
    /// What Swiit code runs under, one task at a time (InterpreterLock.swift).
    let lock = InterpreterLock()
    /// Tasks started and not yet ended.
    var runningTasks = 0
    /// Each enum's associated value types, by case, for checking them.
    var enumPayloadTypes: [ObjectIdentifier: [String: [TypeAnnotation]]] = [:]
    /// The protocols each enum declares.
    var enumConformances: [ObjectIdentifier: [String]] = [:]
    /// The module a program's types are in, shown before their names where Swift shows it (`main.Point`).
    var moduleName = "main"
    var enumTypeParameters: [ObjectIdentifier: [String]] = [:]
    /// What each enum adds to its cases: computed properties, methods, and the static ones.
    var enumMembers: [ObjectIdentifier: TypeMembers] = [:]
    /// The operators and precedence groups declared at the prompt, by what they declare, as source.
    var declaredOperators: [String: String] = [:]
    /// Instances released since a statement began, whose `deinit` runs at the next one.
    var pendingDeinits: [ClassInstance] = []
    nonisolated(unsafe) var hasPendingDeinits = false // safe: a hint, set holding `deinitLock`; a stale read only delays a `deinit` by a statement
    let deinitLock = NSLock()
    /// What extensions add to a type, by the type's name (`Int`, `Array`, a struct's).
    var typeExtensions: [String: TypeMembers] = [:]
    /// Methods every sequence has, like `sorted` and `filter`.
    var sequenceMethods: [String: OverloadSet] = [:]
    /// The declared types of globals, from entries already checked, so a
    /// later one knows `let xs: [Int] = []` is an [Int].
    var staticTypes: [String: TypeAnnotation] = [:]
    /// What reads source into the tree: SwiftParser's, lowered, unless given another.
    var frontEnd: any SyntaxFrontEnd = SwiftSyntaxFrontEnd()
    /// The file being run, for `#filePath`; nil at the prompt.
    /// The script being run, as errors and `#filePath` name it.
    public var file: String?
    /// For each function, the functions declared at the prompt that call it
    /// without `await`, for the redefinition rule (TypeChecker+Effects.swift).
    var unawaitedCallers: [String: Set<String>] = [:]
    /// Told each simple statement as it finishes, for a host that keeps an
    /// exit status, as the shell does.
    /// Whether the host is told as statements finish; not while a `defer` cleans up.
    var observesStatements = true

    /// What bounds a run (steps, depth, time, output), counted from the start
    /// of each `eval`.
    var limits = Interpreter.Limits()
    var steps = 0
    var deadline: ContinuousClock.Instant?
    /// What a run has written, against `limits.output`.
    let outputCounter: OutputCounter

    init(host: Interpreter.Host, outputCounter: OutputCounter) {
        self.host = host
        self.outputCounter = outputCounter
        self.task = mainTask
    }
}

extension Interpreter {
    /// Reports an error, to wherever standard error is redirected.
    func report(_ message: String) {
        let styled = host.error.traits().styled
        if message.hasPrefix("error: ") {
            host.error.write("\(host.name): error:".styled(DisplayStyle.error, styled) + message.dropFirst(6) + "\n")
        } else {
            host.error.write("\(host.name):".styled(DisplayStyle.error, styled) + " \(message)\n")
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
        scopes[0].bindings.merging(scopes[1].bindings) { $1 }.mapValues { binding in
            if binding.isFunction { return .function }
            if binding.isComputed { return .variable }
            if case .object(is EnumType) = binding.value { return .type }
            if case .object(is StructType) = binding.value { return .type }
            if case .object(is ProtocolType) = binding.value { return .type }
            if case .object(is BridgedTypeName) = binding.value { return .type }
            return .variable
        }.merging(declaredOperators.mapValues(NameKind.operatorDeclaration)) { $1 }
    }
}
