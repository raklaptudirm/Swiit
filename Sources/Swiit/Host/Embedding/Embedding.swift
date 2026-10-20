import Foundation

// The embedding API (Docs/embedding.md): make an interpreter, give it
// functions and values, run source, and get a value or a diagnostic back.

/// What went wrong in a run, as a value: its kind, the message the shell
/// would print, and where in the source it is when that is known.
public struct Diagnostic: Error, CustomStringConvertible, Equatable, Sendable {
    public enum Kind: Sendable { case syntax, type, runtime, limit, cancelled }

    public var kind: Kind
    public var message: String
    /// 1-based, for a type error in a multi-line program.
    @_spi(Layer) public var line: Int?
    /// Where it is in the source: the statement a type or run-time error is in, the token a syntax error is at.
    public var range: SourceRange?
    /// For a run-time error: the calls it came out of, innermost first, with where each was made.
    public var calls: [Call] = []

    /// A function a run-time error came out of, and where it was called.
    public struct Call: Sendable {
        public var function: String
        public var site: SourceRange?

        public init(function: String, site: SourceRange?) {
            self.function = function
            self.site = site
        }
    }
    /// For a run-time error: the status the failure gives (a failed command's own, for a shell).
    public var status: Int32 = 1
    /// The host reported it already (`ScriptError.isReported`).
    public var isReported = false
    /// What a host function threw to end the run (`Unwinding`), or the `ScriptError` it threw.
    public var cause: (any Error)?

    @_spi(Layer) public init(kind: Kind, message: String, line: Int? = nil, range: SourceRange? = nil, calls: [Call] = [],
                             status: Int32 = 1, isReported: Bool = false, cause: (any Error)? = nil) {
        self.kind = kind
        self.message = message
        self.line = line ?? range?.startLine
        self.range = range
        self.calls = calls
        self.status = status
        self.isReported = isReported
        self.cause = cause
    }

    /// A diagnostic is `Sendable` and the error it carries is whatever the host threw.
    @_spi(Layer) public init(runtime error: RuntimeError, isReported: Bool = false) {
        self.init(kind: .runtime, message: error.description, range: error.range, calls: error.calls, status: error.status, isReported: isReported)
    }

    /// What any error that came out of a run is, as a diagnostic.
    static func of(_ error: any Error) -> Diagnostic {
        switch error {
        case let diagnostic as Diagnostic: diagnostic
        case let error as TypeError: Diagnostic(kind: .type, message: error.message, line: error.line, range: error.spot ?? error.range)
        case let error as RuntimeError: Diagnostic(runtime: error)
        case let reported as AlreadyReported: Diagnostic(runtime: reported.error, isReported: true)
        case let fatal as FatalError: Diagnostic(runtime: fatal.error)
        case let limit as LimitExceeded: Diagnostic(kind: .limit, message: limit.description)
        case is Cancelled: Diagnostic(kind: .cancelled, message: "cancelled")
        case is Interrupted: Diagnostic(kind: .cancelled, message: "interrupted")
        case let error as ScriptError: Diagnostic(kind: .runtime, message: error.message, status: error.status, isReported: error.isReported, cause: error)
        default: Diagnostic(kind: .runtime, message: "\(error)", cause: error)
        }
    }

    public static func == (lhs: Diagnostic, rhs: Diagnostic) -> Bool {
        lhs.kind == rhs.kind && lhs.message == rhs.message && lhs.line == rhs.line && lhs.range == rhs.range
    }

    public var description: String { line.map { "line \($0): \(message)" } ?? message }

    /// How a diagnostic is styled, for a host that shows it on a terminal: the escape for each
    /// character of a source text, what the frame of the excerpt and the marks are written in,
    /// and what ends a style.
    @_spi(Layer) public struct Style: Sendable {
        /// Plain ANSI: the frame in bold blue, the marks in bold red, the source as it is.
        public static let ansi = Style(source: { Array(repeating: nil, count: $0.count) }, frame: { "\u{1B}[1;34m\($0)\u{1B}[0m" },
                                       mark: { "\u{1B}[1;31m\($0)\u{1B}[0m" }, reset: "\u{1B}[0m")

        public var source: @Sendable (String) -> [String?]
        public var frame: @Sendable (String) -> String
        public var mark: @Sendable (String) -> String
        public var reset: String

        public init(source: @escaping @Sendable (String) -> [String?], frame: @escaping @Sendable (String) -> String,
                    mark: @escaping @Sendable (String) -> String, reset: String) {
            self.source = source
            self.frame = frame
            self.mark = mark
            self.reset = reset
        }
    }

    /// The diagnostic as a compiler shows one: what is wrong, then the line of the source it is in,
    /// with the place marked. `source` is the text that was run; `path` names it, if it came from a file.
    /// `style`, if given, makes the result styled: the source in the colors it has where it is written,
    /// the marks and places in their own.
    public func rendered(in source: String, path: String? = nil, color: Bool = false) -> String {
        rendered(in: source, path: path, style: color ? .ansi : nil)
    }

    /// As above, styled as a host says (a shell's syntax highlighting).
    @_spi(Layer) public func rendered(in source: String, path: String? = nil, style: Style?) -> String {
        // A syntax error's own text says its line, which the excerpt shows.
        var text = message
        if let match = text.range(of: #" \(line \d+\)$"#, options: .regularExpression) { text.removeSubrange(match) }
        let heading = (kind == .syntax ? "syntax error: " : "error: ") + text
        let place = range ?? line.map { SourceRange(line: $0) }
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let styles = style?.source(normalized)
        guard let place, let first = Diagnostic.excerpt(of: place, in: normalized, path: path, styles: styles, style: style) else { return heading }
        var result = heading + "\n" + first
        // Where the functions it came out of were called from.
        for call in calls {
            guard let site = call.site, let shown = Diagnostic.excerpt(of: site, in: normalized, path: path, styles: styles, style: style) else { continue }
            let label = style?.frame("note:") ?? "note:"
            result += "\n\(label) in '\(call.function)', called from here\n" + shown
        }
        return result
    }

    /// A line of the source with a range in it marked, and where it is.
    static func excerpt(of place: SourceRange, in source: String, path: String?, styles: [String?]? = nil, style: Style? = nil) -> String? {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        guard place.startLine >= 1, place.startLine <= lines.count else { return nil }
        let shown = String(lines[place.startLine - 1])
        let characters = Array(shown)
        // From the start column to the end of the range, or of the line if it goes on; a whole-line mark is the line's text.
        var from = max(place.startColumn - 1, 0)
        var to = place.endLine == place.startLine ? place.endColumn - 1 : characters.count
        if place.startColumn == 1, place.endColumn == 1, place.endLine == place.startLine {
            from = characters.firstIndex { $0 != " " && $0 != "\t" } ?? 0
            to = characters.count
        }
        from = min(from, characters.count)
        to = min(max(to, from + 1), max(characters.count, from + 1))
        let number = String(place.startLine)
        let gutter = String(repeating: " ", count: number.count)
        let indent = characters.prefix(from).map { $0 == "\t" ? "\t" : " " }.joined()
        let marks = String(repeating: "^", count: max(to - from, 1))
        let location = (path.map { "\($0):" } ?? "") + "\(place.startLine):\(from + 1)"
        func frame(_ text: String) -> String { style?.frame(text) ?? text }
        // The line in the colors it has where it is written: the styles are by character of the whole source.
        var body = shown
        if let styles {
            let before = lines[..<(place.startLine - 1)].reduce(0) { $0 + $1.count + 1 }
            body = ""
            var current: String?
            for (index, character) in characters.enumerated() {
                let escape = before + index < styles.count ? styles[before + index] : nil
                if escape != current {
                    if current != nil { body += style?.reset ?? "" }
                    if let escape { body += escape }
                    current = escape
                }
                body.append(character)
            }
            if current != nil { body += style?.reset ?? "" }
        }
        return "\(gutter)\(frame("-->")) \(location)\n\(gutter) \(frame("|"))\n\(frame(number + " |")) \(body)\n\(gutter) \(frame("|")) \(indent)\((style?.mark(marks) ?? marks))"
    }
}

extension Interpreter {
    /// What bounds a run. Each is checked as the script runs; a script that hits
    /// one stops with a `.limit` diagnostic, which it can't catch. Memory isn't
    /// limited: a script that builds a huge list is bounded only by steps and time.
    public struct Limits: Sendable {
        /// Statements and calls. Nil is no limit.
        public var steps: Int?
        /// Nested Swiit function calls.
        public var depth: Int
        public var time: Duration?
        /// Bytes written to the host's output and error.
        public var output: Int?
        /// Tasks running at once, each on a thread of its own.
        public var tasks: Int

        public init(steps: Int? = nil, depth: Int = 10_000, time: Duration? = nil, output: Int? = nil, tasks: Int = 256) {
            self.steps = steps
            self.depth = depth
            self.time = time
            self.output = output
            self.tasks = tasks
        }
    }
}

@_spi(Layer) public struct LimitExceeded: Error, CustomStringConvertible {
    public let description: String
    @_spi(Layer) public init(_ description: String) { self.description = description }
}

@_spi(Layer) public struct Cancelled: Error {}

/// Bytes written so far, for the output limit.
@_spi(Layer) public final class OutputCounter: @unchecked Sendable { // safe: every access holds its own lock
    private let lock = NSLock()
    private var count = 0

    public init() {}

    public var written: Int { lock.withLock { count } }
    public func add(_ bytes: Int) { lock.withLock { count += bytes } }
    @_spi(Layer) public func reset() { lock.withLock { count = 0 } }
}

/// A request to stop, from any thread.
/// A request to stop a task, which a host can ask about before it waits.
public final class Cancellation: @unchecked Sendable { // safe: every access holds its own lock
    private let lock = NSLock()
    private var set = false
    /// What `isSet` reads without the lock, which every step of every script asks. It is a word written under the lock and
    /// read by whoever is running: a stale read only delays the stop by a step, and a load of a word is atomic where this
    /// runs (arm64 and x86-64), as the SIGINT flag in the shell's spawn code is.
    nonisolated(unsafe) private var flag: UnsafeMutablePointer<Int32> = {
        let pointer = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        pointer.initialize(to: 0)
        return pointer
    }()

    deinit { flag.deallocate() }
    /// What wakes the waits going on now, so a request ends them early.
    private var wakers: [Int: () -> Void] = [:]
    private var nextWaker = 0

    @_spi(Layer) public init() {}

    public var isSet: Bool { readFlag() != 0 }

    /// Not inlined, so that a loop asking again reads the word again.
    @inline(never)
    private func readFlag() -> Int32 { flag.pointee }

    /// Asks for the stop, and wakes what is waiting.
    func request() {
        let wake = lock.withLock { () -> [() -> Void] in
            set = true
            flag.pointee = 1
            return Array(wakers.values)
        }
        wake.forEach { $0() }
    }

    @_spi(Layer) public func clear() { lock.withLock { set = false; flag.pointee = 0 } }

    /// Calls `wake` when the stop is asked for (now, if it was already), until
    /// `remove` is given what this gives.
    func onRequest(_ wake: @escaping () -> Void) -> Int {
        let (token, already) = lock.withLock { () -> (Int, Bool) in
            nextWaker += 1
            wakers[nextWaker] = wake
            return (nextWaker, set)
        }
        if already { wake() }
        return token
    }

    @_spi(Layer) public func remove(_ token: Int) {
        lock.withLock { _ = wakers.removeValue(forKey: token) }
    }
}

extension Interpreter {
    /// An interpreter with Swift's syntax, the standard library and nothing
    /// else: no commands, no environment, no files. What a script can name
    /// is what the host registers.
    public convenience init(host: Interpreter.Host = Interpreter.Host(), limits: Interpreter.Limits = Interpreter.Limits()) {
        let counter = OutputCounter()
        func counted(_ sink: OutputSink) -> OutputSink {
            OutputSink(write: { counter.add($0.utf8.count); return sink.write($0) }, traits: sink.traits)
        }
        self.init(host: Interpreter.Host(name: host.name, output: counted(host.output), error: counted(host.error), interrupt: host.interrupt,
                                  startThread: host.startThread),
                  outputCounter: counter)
        self.limits = limits
        installBuiltinFunctions()
    }

    /// `print("a", 1)`: its arguments, as interpolation shows them, separated
    /// by spaces, then a newline, to the host's output. The one way a script
    /// speaks, since a bare value gives nothing here.
    func installPrint() {
        nonisolated(unsafe) let interpreter = self // safe: runs holding the interpreter lock
        let print = hostFunction(HostFunction(
            name: "print", summary: "Writes its arguments to the output, separated by spaces, then a newline.",
            parameters: [HostFunction.Parameter(label: nil, name: "items", type: .any, variadic: true, showsByType: true),
                         HostFunction.Parameter(label: "separator", name: "separator", type: .string, defaultValue: .string(" ")),
                         HostFunction.Parameter(label: "terminator", name: "terminator", type: .string, defaultValue: .string("\n"))],
            returnType: nil,
            call: { arguments in
                guard case .list(let items)? = arguments["items"] else { return .nothing }
                var separator = " ", terminator = "\n"
                if case .string(let text)? = arguments["separator"] { separator = text }
                if case .string(let text)? = arguments["terminator"] { terminator = text }
                let line = try items.map { try interpreter.describing($0) }.joined(separator: separator)
                interpreter.host.output.write(line + terminator)
                return .nothing
            }
        ))
        scopes[0].declare(print, named: "print")
    }

    /// Asks a run in progress to stop, from any thread. It ends with a
    /// `.cancelled` diagnostic; the next `evaluate` starts afresh.
    public func cancel() { cancellation.request() }

    // MARK: Values

    /// A global of the script: what `name` is bound to, if anything. Setting one makes it a constant for scripts to read; a
    /// `DynamicObject` is described to the checker as it is set.
    public subscript(name: String) -> Value? {
        get { withMainTask { lookup(name)?.value } }
        set {
            withMainTask {
                guard let newValue else {
                    scopes[1].bindings[name] = nil
                    return
                }
                if case .object(let object as any DynamicObject) = newValue { bind(name, to: object) }
                scopes[1].bindings[name] = Binding(value: newValue, mutable: false)
            }
        }
    }

    /// A member of a value as a script reads it: `value(of: "columns", in: type)` is `Type.columns`.
    public func value(of member: String, in value: Value) throws(Diagnostic) -> Value {
        do {
            return try withMainTask { try self.member(member, of: value) }
        } catch {
            throw Diagnostic.of(error)
        }
    }

    /// Calls a function by name, or a method of `receiver`, as a script's call with these arguments would: the overload is
    /// chosen by the labels and the values given, and what is left out takes its default. A struct or enum type given as the
    /// receiver calls its static members and initializers (`call("init", on: type)`). From a host function it runs in the
    /// calling script's task; from outside, as the main one.
    @discardableResult
    public func call(
        _ name: String, on receiver: Value? = nil, arguments: [(label: String?, value: Value)] = []
    ) throws(Diagnostic) -> Value {
        let callee: Expr = receiver.map { .member(.literal($0), name) } ?? .variable(name)
        let call = Expr.call(callee, arguments.map { Argument(label: $0.label, value: .literal($0.value)) })
        do {
            return try inCurrentTask { try self.evaluate(call) }
        } catch {
            throw Diagnostic.of(error)
        }
    }

    /// Runs `body` as the task that is running now, or as the main one when no script is.
    func inCurrentTask<T>(_ body: () throws -> T) rethrows -> T {
        lock.isHeldByCurrentThread ? try body() : try withMainTask(body)
    }

    // MARK: Functions

    /// Makes a described function one scripts can call, checked like any they declare.
    public func register(_ function: HostFunction) {
        withMainTask { scopes[1].declare(hostFunction(function), named: function.name) }
    }

    /// Makes a Swift closure a function scripts can call. Its parameters and
    /// result convert as SwiitKit's `ValueConvertible` says, and a script
    /// sees an ordinary function: `labels` are its argument labels (`nil`
    /// or missing for none), and a wrong argument is the usual type error.
    public func register<each Argument: ValueConvertible, Result: ValueConvertible>(
        _ name: String, labels: [String?] = [], throwing: Bool = false,
        _ body: @escaping @Sendable (repeat each Argument) throws -> Result
    ) {
        install(name, labels: labels, throwing: throwing, returns: Result.valueType, enums: Result.swiitEnums,
                parameterTypes: Self.types(repeat (each Argument).self)) { arguments in
            var index = 0
            func next() -> Value {
                defer { index += 1 }
                return arguments[index]
            }
            return try body(repeat try (each Argument)(next())).value
        }
    }

    /// As above, for a closure that returns nothing.
    public func register<each Argument: ValueConvertible>(
        _ name: String, labels: [String?] = [], throwing: Bool = false,
        _ body: @escaping @Sendable (repeat each Argument) throws -> Void
    ) {
        install(name, labels: labels, throwing: throwing, returns: nil, enums: [],
                parameterTypes: Self.types(repeat (each Argument).self)) { arguments in
            var index = 0
            func next() -> Value {
                defer { index += 1 }
                return arguments[index]
            }
            try body(repeat try (each Argument)(next()))
            return .nothing
        }
    }

    private static func types<each Argument: ValueConvertible>(_: repeat (each Argument).Type) -> [(ValueType, [EnumType])] {
        var types: [(ValueType, [EnumType])] = []
        func add<T: ValueConvertible>(_: T.Type) { types.append((T.valueType, T.swiitEnums)) }
        repeat add((each Argument).self)
        return types
    }

    private func install(
        _ name: String, labels: [String?], throwing: Bool, returns: ValueType?, enums: [EnumType],
        parameterTypes: [(ValueType, [EnumType])], call: @escaping @Sendable ([Value]) throws -> Value
    ) {
        let parameters = parameterTypes.enumerated().map { index, entry in
            let label = labels.indices.contains(index) ? labels[index] : nil
            return HostFunction.Parameter(label: label, name: label ?? "argument\(index)", type: entry.0, enums: entry.1)
        }
        let names = parameters.map(\.name)
        let function = hostFunction(HostFunction(
            name: name, parameters: parameters, returnType: returns, isThrowing: throwing,
            call: { arguments in try call(names.map { arguments[$0] ?? .nothing }) }
        ))
        for type in parameterTypes.flatMap(\.1) + enums {
            scopes[1].bindings[type.name] = Binding(value: .object(type), mutable: false)
        }
        scopes[1].declare(function, named: name)
    }

    // MARK: Running

    /// Runs source and gives the value of its last statement if that is an
    /// expression (nothing otherwise). Runs on a thread with a large stack.
    /// Declarations and values stay for the next call.
    @discardableResult
    public func evaluate(_ source: String) throws(Diagnostic) -> Value {
        try evaluate(source, alreadyCancelled: { false })
    }

    /// `alreadyCancelled` is asked once the run has started afresh, so a request made before that is not lost.
    private func evaluate(_ source: String, alreadyCancelled: @escaping () -> Bool) throws(Diagnostic) -> Value {
        // Nothing else runs on this interpreter meanwhile.
        nonisolated(unsafe) let interpreter = self // safe: runs holding the interpreter lock
        do {
            // Swiit code runs holding the lock, which a task it starts waits for.
            return try onLargeStack { try interpreter.withMainTask { try interpreter.runSource(source, alreadyCancelled: alreadyCancelled) } }
        } catch {
            throw Diagnostic.of(error)
        }
    }

    /// As `evaluate`, on a thread of the interpreter's own, and cancelled when the calling task is.
    @discardableResult
    public func evaluate(_ source: String) async throws(Diagnostic) -> Value {
        let cancelled = CancelFlag()
        let outcome: Result<Value, Diagnostic> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                nonisolated(unsafe) let interpreter = self // safe: runs holding the interpreter lock
                startLargeStackThread {
                    continuation.resume(returning: Result { () throws(Diagnostic) -> Value in
                        try interpreter.evaluate(source, alreadyCancelled: { cancelled.isSet })
                    })
                }
            }
        } onCancel: {
            cancelled.set()
            cancel()
        }
        return try outcome.get()
    }

    private func runSource(_ source: String, alreadyCancelled: () -> Bool) throws -> Value {
        steps = 0
        outputCounter.reset()
        deadline = limits.time.map { ContinuousClock.now + $0 }
        cancellation.clear()
        if alreadyCancelled() { cancellation.request() }
        let program: Program
        switch parse(source) {
        case .failure(let error): throw Diagnostic(kind: .syntax, message: error.description, range: error.range)
        case .success(let parsed): program = parsed
        }
        do {
            var checked = try TypeChecker(interpreter: self).check(program)
            var last: Expr?
            var lastRange: SourceRange?
            if case .expression(let expr)? = checked.statements.last {
                last = expr
                lastRange = checked.ranges.last
                checked.statements.removeLast()
                if checked.lines.count > checked.statements.count { checked.lines.removeLast() }
                if checked.ranges.count > checked.statements.count { checked.ranges.removeLast() }
                if checked.spots.count > checked.statements.count { checked.spots.removeLast() }
            }
            try run(checked)
            do {
                return try last.map { try evaluate($0) } ?? .nothing
            } catch var error as RuntimeError {
                if error.range == nil {
                    error.range = lastRange
                } else if let last = error.calls.indices.last, error.calls[last].site == nil {
                    error.calls[last].site = lastRange
                }
                throw error
            }
        } catch {
            throw Diagnostic.of(error)
        }
    }
}

/// Whether the task running an `async` evaluation has been cancelled, which the thread asks as it starts.
private final class CancelFlag: @unchecked Sendable { // safe: every access holds the lock
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
