import Foundation
import SwiitKit

/// The language: its scopes, what the checker remembers between entries, and
/// the evaluator (the `Interpreter+…` files). It knows nothing of the
/// terminal, processes or jobs: it reaches the world through its `host`, and
/// runs only Swift (a layer over it, like the shell, rewrites its own syntax
/// first; Docs/Design/boundaries.md). The shell owns one.
public final class Interpreter {
    /// How this interpreter is run: where its output goes, how to tell it to stop.
    @_spi(Host) public var host: SwiitHost

    /// What runs this interpreter, if it is more than an embedder's call: the
    /// shell, whose nodes reach it from here. Weak, as the owner holds the
    /// interpreter.
    @_spi(Host) public weak var owner: AnyObject?
    /// The members, by name, of the host's object types that Swift doesn't
    /// declare (the shell's `Job`), for the checker.
    /// The bridged libraries installed: the core's, and the host's.
    @_spi(Host) public var libraries: [Library] = []
    /// The types of dynamic objects' members (`DynamicObject`), by type name.
    @_spi(Host) public var dynamicTypes: [String: DynamicType] = [:]
    /// How values lay out as tables, which only a host that shows them has
    /// (the shell installs it). Library functions that format are lent this.
    @_spi(Host) public var displayRegistryProvider: () -> DisplayRegistry = { DisplayRegistry() }
    /// What `await` waits for, if the host has anything to wait for.
    @_spi(Host) public var awaiting: Awaiting?
    @_spi(Host) public var objectMembers: [String: [String: TypeAnnotation]] = [:]

    /// The task running now: its call stack and cancellation (TaskContext.swift).
    @_spi(Host) public var task: TaskContext
    /// The first task: the host's own (the shell's prompt, an embedder's `eval`).
    @_spi(Host) public let mainTask = TaskContext(globals: [Scope(), Scope()])
    /// What Swiit code runs under, one task at a time (InterpreterLock.swift).
    @_spi(Host) public let lock = InterpreterLock()
    /// Tasks started and not yet ended.
    var runningTasks = 0
    /// How a read of the host's input waits for the current task's turn at it
    /// (the shell: a task in the background waits until it's awaited); then it
    /// runs the read, or doesn't, if the task is cancelled first.
    @_spi(Host) public var inputTurn: ((_ read: () -> Void) -> Void)?
    /// Told when the current task waits for `handle` to end (`join`), before
    /// it does; what it gives back is called once the wait is over.
    @_spi(Host) public var awaitingTask: ((_ handle: TaskHandle) -> () -> Void)?
    /// What the host keeps for a task the language starts (Swift's `Task { }`,
    /// `async let`), as it passes its own to `startTask`.
    @_spi(Host) public var newTaskHost: (() -> AnyObject?)?
    /// Each enum's associated value types, by case, for checking them.
    var enumPayloadTypes: [ObjectIdentifier: [String: [TypeAnnotation]]] = [:]
    /// The protocols each enum declares.
    var enumConformances: [ObjectIdentifier: [String]] = [:]
    /// Methods every sequence has, like `sorted` and `filter`.
    @_spi(Host) public var sequenceMethods: [String: OverloadSet] = [:]
    /// The declared types of globals, from entries already checked, so a
    /// later one knows `let xs: [Int] = []` is an [Int].
    @_spi(Host) public var staticTypes: [String: TypeAnnotation] = [:]
    /// Syntax added to Swift's, which its owner supplies (the shell's). Nil is
    /// Swift alone.
    @_spi(Host) public var syntax: (any SyntaxPlugin)?
    /// What reads source into the tree: the hand-written parser unless given another.
    @_spi(Host) public var frontEnd: any SyntaxFrontEnd = HandWrittenFrontEnd()
    /// The file being run, for `#filePath`; nil at the prompt.
    @_spi(Host) public var file: String?
    /// For each function, the functions declared at the prompt that call it
    /// without `await`, for the redefinition rule (TypeChecker+Effects.swift).
    var unawaitedCallers: [String: Set<String>] = [:]
    /// Told each simple statement as it finishes, for a host that keeps an
    /// exit status, as the shell does.
    @_spi(Host) public var statementFinished: StatementObserver?
    /// What library functions that ask for it are lent, if the host lends its
    /// own (`context` otherwise makes one from the output and the display).
    @_spi(Host) public var contextProvider: (() -> HostContext)?

    /// What bounds a run (steps, depth, time, output), counted from the start
    /// of each `eval`.
    @_spi(Host) public var limits = Limits()
    var steps = 0
    @_spi(Host) public var deadline: ContinuousClock.Instant?
    /// What a run has written, against `limits.output`.
    @_spi(Host) public let outputCounter: OutputCounter

    @_spi(Host) public init(host: SwiitHost, outputCounter: OutputCounter) {
        self.host = host
        self.outputCounter = outputCounter
        self.task = mainTask
    }
}

extension Interpreter {
    /// Reports an error, to wherever standard error is redirected.
    @_spi(Host) public func report(_ message: String) {
        let styled = host.error.traits().styled
        if message.hasPrefix("error: ") {
            host.error.write("\(host.name): error:".styled(DisplayStyle.error, styled) + message.dropFirst(6) + "\n")
        } else {
            host.error.write("\(host.name):".styled(DisplayStyle.error, styled) + " \(message)\n")
        }
    }

    /// Reports a problem with one item, like a file `ls` couldn't read,
    /// without stopping; the statement's status becomes a failure.
    @_spi(Host) public func reportItemError(_ message: String) {
        report(message)
        itemErrorCount += 1
    }
}

extension Interpreter {
    /// Parses a program, knowing the names already declared.
    @_spi(Host) public func parse(_ source: String) -> Result<Program, SyntaxError> {
        do {
            return .success(try frontEnd.parse(source, bound: globalNames(), plugin: syntax))
        } catch {
            return .failure(error)
        }
    }

    /// Names the parser should know: builtins and globals, as variables or functions.
    @_spi(Host) public func globalNames() -> [String: NameKind] {
        scopes[0].bindings.merging(scopes[1].bindings) { $1 }.mapValues { binding in
            if binding.isFunction { return .function }
            if binding.isComputed { return .variable }
            if case .object(is EnumType) = binding.value { return .type }
            if case .object(is StructType) = binding.value { return .type }
            if case .object(is BridgedTypeName) = binding.value { return .type }
            return .variable
        }
    }
}
