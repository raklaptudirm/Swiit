import Foundation
import Synchronization

// The embedding API (Docs/embedding.md): make an interpreter, give it
// functions and values, run source, and get a value or a diagnostic back.

/// What went wrong in a run, as a value: what kind of failure it was, the message the host would
/// print, and where in the source it is when that is known. What a kind carries is what that kind
/// has: only a run-time failure has a thrown value for a script to catch, and only a syntax error
/// can be a program that is not finished.
public struct Diagnostic: Error, CustomStringConvertible, Equatable, Sendable {
    public var message: String
    public var kind: Kind
    /// Where it is in the source: the statement a type or run-time error is in, the token a syntax
    /// error is at.
    public var range: SourceRange?

    public enum Kind: Sendable, Equatable {
        /// A syntax error. `isIncomplete`: the source ends too soon, and more of it may make it a
        /// program (a prompt asks for another line).
        case syntax(isIncomplete: Bool)
        case type
        /// A failure a script's `catch` sees, from the language or from a host function.
        case runtime(Failure)
        /// A failure that ends the run, which a script's `catch` does not see and its `defer`s
        /// run for: a failed `try!`, or a host function ending the script (a shell's `exit`).
        case fatal(Failure)
        /// A limit of the run (`Limits`) was reached.
        case limit
        case cancelled

        public static func == (lhs: Kind, rhs: Kind) -> Bool {
            switch (lhs, rhs) {
            case (.syntax(let a), .syntax(let b)): a == b
            case (.type, .type), (.limit, .limit), (.cancelled, .cancelled): true
            case (.runtime(let a), .runtime(let b)), (.fatal(let a), .fatal(let b)): a == b
            default: false
            }
        }
    }

    /// What a failure that ran has beyond its message.
    public struct Failure: Sendable, Equatable {
        /// What a script's `catch` binds.
        public var thrown: Thrown
        /// Who raised it.
        public var origin: Origin
        /// The functions it came out of, innermost first, with where each was called.
        public var calls: [Call]
        /// Where the host prints it.
        public var destination: Destination

        public init(
            thrown: Thrown = .message,
            origin: Origin = .language,
            calls: [Call] = [],
            destination: Destination = .standard
        ) {
            self.thrown = thrown
            self.origin = origin
            self.calls = calls
            self.destination = destination
        }

        public enum Destination: Sendable {
            /// The host's own error output.
            case standard
            /// The output that `Interpreter.withErrorOutput` set where it was raised, as a shell's
            /// `f 2>file` sends `f`'s errors to the file.
            case sink(OutputSink)
        }

        public enum Thrown: Sendable, Equatable {
            /// An `Error` whose description is the message.
            case message
            /// A value the host built: a struct with the failure's fields.
            case value(Value)
        }

        public enum Origin: Sendable, Equatable {
            /// The language: division by zero, an index out of range.
            case language
            /// A host function, with nothing of its own attached.
            case host
            /// A host function, with an error of its own, which the host reads back (a status, a
            /// stop it asked for).
            case hostError(any Error)

            public static func == (lhs: Origin, rhs: Origin) -> Bool {
                switch (lhs, rhs) {
                case (.language, .language), (.host, .host): true
                case (.hostError(let a), .hostError(let b)): "\(a)" == "\(b)"
                default: false
                }
            }
        }

        public static func == (lhs: Failure, rhs: Failure) -> Bool {
            lhs.thrown == rhs.thrown && lhs.origin == rhs.origin
        }
    }

    /// A function a run-time error came out of, and where it was called.
    public struct Call: Sendable, Equatable {
        public var function: String
        public var site: SourceRange?

        public init(function: String, site: SourceRange?) {
            self.function = function
            self.site = site
        }
    }

    public init(kind: Kind, message: String, range: SourceRange? = nil) {
        self.kind = kind
        self.message = message
        self.range = range
    }

    /// How a host function fails so a script can see it: the message is what is reported, and a
    /// script's `catch` binds an `Error` of it, or `thrown` when there is more to say. `cause` is
    /// the host's own error, for the host to read back.
    public static func runtime(
        _ message: String,
        thrown: Value? = nil,
        cause: (any Error)? = nil
    ) -> Diagnostic {
        Diagnostic(
            kind: .runtime(
                Failure(
                    thrown: thrown.map { .value($0) } ?? .message,
                    origin: cause.map { .hostError($0) } ?? .host
                )
            ),
            message: message
        )
    }

    /// How a host function ends the run: a script's `catch` and `try?` let it go by, its `defer`s
    /// run, and it reaches the host as this diagnostic.
    public static func fatal(_ message: String, cause: (any Error)? = nil) -> Diagnostic {
        Diagnostic(
            kind: .fatal(Failure(origin: cause.map { .hostError($0) } ?? .host)),
            message: message
        )
    }

    /// What a failure that ran has, for a kind that can: nil for the others.
    public var failure: Failure? {
        switch kind {
        case .runtime(let failure), .fatal(let failure): failure
        default: nil
        }
    }

    /// The language's own run-time error, as a diagnostic.
    init(runtime error: RuntimeError) {
        self.init(
            kind: .runtime(
                Failure(
                    thrown: error.thrown.map { .value($0) } ?? .message,
                    origin: error.origin,
                    calls: error.calls,
                    destination: error.destination
                )
            ),
            message: error.description,
            range: error.range
        )
    }

    /// What any error that came out of a run is, as a diagnostic.
    static func of(_ error: any Error) -> Diagnostic {
        switch error {
        case let diagnostic as Diagnostic: diagnostic
        case let error as TypeError:
            Diagnostic(
                kind: .type,
                message: error.message,
                range: error.spot ?? error.range ?? error.line.map { SourceRange(line: $0) }
            )
        case let error as RuntimeError: Diagnostic(runtime: error)
        case let fatal as FatalError:
            { () -> Diagnostic in
                var diagnostic = Diagnostic(runtime: fatal.error)
                if case .runtime(let failure) = diagnostic.kind {
                    diagnostic.kind = .fatal(failure)
                }
                return diagnostic
            }()
        case let limit as LimitExceeded: Diagnostic(kind: .limit, message: limit.description)
        case is Cancelled: Diagnostic(kind: .cancelled, message: "cancelled")
        case is Interrupted: Diagnostic(kind: .cancelled, message: "interrupted")
        default: Diagnostic.runtime("\(error)", cause: error)
        }
    }

    public static func == (lhs: Diagnostic, rhs: Diagnostic) -> Bool {
        lhs.kind == rhs.kind && lhs.message == rhs.message && lhs.range == rhs.range
    }

    public var description: String {
        range.map { "line \($0.startLine): \(message)" } ?? message
    }

    /// How a diagnostic is styled, for a host that shows it on a terminal: the escape for each
    /// character of a source text, what the frame of the excerpt and the marks are written in,
    /// and what ends a style.
    public struct Style: Sendable {
        /// Plain ANSI: the frame in bold blue, the marks in bold red, the source as it is.
        public static let ansi = Style(
            source: { Array(repeating: nil, count: $0.count) },
            frame: { "\u{1B}[1;34m\($0)\u{1B}[0m" },
            mark: { "\u{1B}[1;31m\($0)\u{1B}[0m" },
            reset: "\u{1B}[0m"
        )

        public var source: @Sendable (String) -> [String?]
        public var frame: @Sendable (String) -> String
        public var mark: @Sendable (String) -> String
        public var reset: String

        public init(
            source: @escaping @Sendable (String) -> [String?],
            frame: @escaping @Sendable (String) -> String,
            mark: @escaping @Sendable (String) -> String,
            reset: String
        ) {
            self.source = source
            self.frame = frame
            self.mark = mark
            self.reset = reset
        }
    }

    /// The diagnostic as a compiler shows one: what is wrong, then the line of the source it is in,
    /// with the place marked. `source` is the text that was run; `path` names it, if it came from a
    /// file. `style`, if given, makes the result styled: the source in the colors it has where it
    /// is written, the marks and places in their own.
    public func rendered(in source: String, path: String? = nil, color: Bool = false) -> String {
        rendered(in: source, path: path, style: color ? .ansi : nil)
    }

    /// As above, styled as a host says (a host's syntax highlighting).
    public func rendered(in source: String, path: String? = nil, style: Style?) -> String {
        // A syntax error's own text says its line, which the excerpt shows.
        var text = message
        if let match = text.range(of: #" \(line \d+\)$"#, options: .regularExpression) {
            text.removeSubrange(match)
        }
        let heading: String
        if case .syntax = kind {
            heading = "syntax error: " + text
        } else {
            heading = "error: " + text
        }
        let place = range
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let styles = style?.source(normalized)
        guard let place,
            let first = Diagnostic.excerpt(
                of: place,
                in: normalized,
                path: path,
                styles: styles,
                style: style
            )
        else { return heading }
        var result = heading + "\n" + first
        // Where the functions it came out of were called from.
        for call in failure?.calls ?? [] {
            guard let site = call.site,
                let shown = Diagnostic.excerpt(
                    of: site,
                    in: normalized,
                    path: path,
                    styles: styles,
                    style: style
                )
            else { continue }
            let label = style?.frame("note:") ?? "note:"
            result += "\n\(label) in '\(call.function)', called from here\n" + shown
        }
        return result
    }

    /// A line of the source with a range in it marked, and where it is.
    static func excerpt(
        of place: SourceRange,
        in source: String,
        path: String?,
        styles: [String?]? = nil,
        style: Style? = nil
    ) -> String? {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        guard place.startLine >= 1, place.startLine <= lines.count else { return nil }
        let shown = String(lines[place.startLine - 1])
        let characters = Array(shown)
        // From the start column to the end of the range, or of the line if it goes on; a whole-line
        // mark is the line's text.
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
        // The line in the colors it has where it is written: the styles are by character of the
        // whole source.
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
        return
            "\(gutter)\(frame("-->")) \(location)\n\(gutter) \(frame("|"))\n\(frame(number + " |")) \(body)\n\(gutter) \(frame("|")) \(indent)\((style?.mark(marks) ?? marks))"
    }
}

extension Interpreter {
    /// What bounds a run. Each is checked as the script runs; a script that hits
    /// one stops with a `.limit` diagnostic, which it can't catch. Memory isn't
    /// limited: a script that builds a huge list is bounded only by steps and time.
    public struct Limits: Sendable {
        /// Statements and calls. Nil is no limit.
        public var maxSteps: Int?
        /// Nested Swiit function calls.
        public var maxCallDepth: Int
        public var timeLimit: Duration?
        /// Bytes written to the host's output and error.
        public var maxOutputBytes: Int?
        /// Tasks running at once, each on a thread of its own.
        public var maxTasks: Int

        public init(
            maxSteps: Int? = nil,
            maxCallDepth: Int = 10_000,
            timeLimit: Duration? = nil,
            maxOutputBytes: Int? = nil,
            maxTasks: Int = 256
        ) {
            self.maxSteps = maxSteps
            self.maxCallDepth = maxCallDepth
            self.timeLimit = timeLimit
            self.maxOutputBytes = maxOutputBytes
            self.maxTasks = maxTasks
        }
    }
}

struct LimitExceeded: Error, Unwinding, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

struct Cancelled: Error, Unwinding {}

/// Bytes written so far, for the output limit.
final class OutputCounter: Sendable {
    private let count = Mutex(0)

    public init() {}

    public var written: Int { count.withLock { $0 } }
    public func add(_ bytes: Int) { count.withLock { $0 += bytes } }
    func reset() { count.withLock { $0 = 0 } }
}

extension Interpreter {
    /// A request to stop, from any thread.
    /// A request to stop a task, which a host can ask about before it waits.
    public final class Cancellation: @unchecked Sendable {  // safe: the state is in a `Mutex`; the flag is a word, below
        private struct State {
            var isRequested = false
            /// What wakes the waits going on now, so a request ends them early.
            var wakers: [Int: @Sendable () -> Void] = [:]
            var nextWaker = 0
        }

        private let state = Mutex(State())
        /// What `isSet` reads without the lock, which every step of every script asks. It is a word
        /// written under the lock and read by whoever is running: a stale read only delays the stop by
        /// a step, and a load of a word is atomic where this runs (arm64 and x86-64), as the SIGINT
        /// flag in the host's spawn code is.
        nonisolated(unsafe) private var flag: UnsafeMutablePointer<Int32> = {
            let pointer = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
            pointer.initialize(to: 0)
            return pointer
        }()

        deinit { flag.deallocate() }

        init() {}

        public var isSet: Bool { readFlag() != 0 }

        /// Not inlined, so that a loop asking again reads the word again.
        @inline(never)
        private func readFlag() -> Int32 { flag.pointee }

        /// Asks for the stop, and wakes what is waiting.
        func request() {
            let wake = state.withLock { state -> [@Sendable () -> Void] in
                state.isRequested = true
                flag.pointee = 1
                return Array(state.wakers.values)
            }
            wake.forEach { $0() }
        }

        func clear() {
            state.withLock { state in
                state.isRequested = false; flag.pointee = 0
            }
        }

        /// Calls `wake` when the stop is asked for (now, if it was already), until
        /// `remove` is given what this gives.
        func onRequest(_ wake: @escaping @Sendable () -> Void) -> Int {
            let (token, already) = state.withLock { state -> (Int, Bool) in
                state.nextWaker += 1
                state.wakers[state.nextWaker] = wake
                return (state.nextWaker, state.isRequested)
            }
            if already { wake() }
            return token
        }

        func remove(_ token: Int) {
            state.withLock { _ = $0.wakers.removeValue(forKey: token) }
        }
    }
}

extension Interpreter {
    /// An interpreter with Swift's syntax, the standard library and nothing
    /// else: no processes, no environment, no files. What a script can name
    /// is what the host registers.
    public convenience init(
        host: Interpreter.Host = Interpreter.Host(),
        limits: Interpreter.Limits = Interpreter.Limits()
    ) {
        let counter = OutputCounter()
        func counted(_ sink: OutputSink) -> OutputSink {
            OutputSink(
                write: {
                    counter.add($0.utf8.count); return sink.write($0)
                },
                traits: sink.traits
            )
        }
        self.init(
            host: Interpreter.Host(
                name: host.name,
                output: counted(host.output),
                error: counted(host.error),
                interrupt: host.interrupt,
                startThread: host.startThread
            ),
            outputCounter: counter
        )
        self.limits = limits
        installBuiltinFunctions()
    }

    /// `print("a", 1)`: its arguments, as interpolation shows them, separated
    /// by spaces, then a newline, to the host's output. The one way a script
    /// speaks, since a bare value gives nothing here.
    func installPrint() {
        nonisolated(unsafe) let interpreter = self  // safe: runs holding the interpreter lock
        let print = hostFunction(
            HostFunction(
                name: "print",
                summary: "Writes its arguments to the output, separated by spaces, then a newline.",
                parameters: [
                    Symbol.Parameter(
                        label: nil,
                        name: "items",
                        type: .any,
                        variadic: true,
                        showsByType: true
                    ),
                    Symbol.Parameter(
                        label: "separator",
                        name: "separator",
                        type: .string,
                        defaultValue: .string(" ")
                    ),
                    Symbol.Parameter(
                        label: "terminator",
                        name: "terminator",
                        type: .string,
                        defaultValue: .string("\n")
                    ),
                ],
                returnType: nil,
                call: { arguments in
                    guard case .list(let items)? = arguments["items"] else { return .nothing }
                    var separator = " ", terminator = "\n"
                    if case .string(let text)? = arguments["separator"] { separator = text }
                    if case .string(let text)? = arguments["terminator"] { terminator = text }
                    let line = try items.map { try interpreter.describing($0) }
                        .joined(separator: separator)
                    interpreter.host.output.write(line + terminator)
                    return .nothing
                }
            )
        )
        scopes[0].declare(print, named: "print")
    }

    /// Asks a run in progress to stop, from any thread. It ends with a
    /// `.cancelled` diagnostic; the next `evaluate` starts afresh.
    public func cancel() { cancellation.request() }

    /// Runs `body` with the errors it raises sent to `output` instead of the host's own: a
    /// failure that comes out of it, and was not caught inside, says so in its `destination`, for
    /// the host that prints it. A shell's `f 2>file` is this.
    public func withErrorOutput<Result>(
        _ output: OutputSink,
        _ body: () throws -> Result
    ) rethrows -> Result {
        do {
            return try body()
        } catch var diagnostic as Diagnostic {
            switch diagnostic.kind {
            case .runtime(var failure):
                if case .standard = failure.destination { failure.destination = .sink(output) }
                diagnostic.kind = .runtime(failure)
            case .fatal(var failure):
                if case .standard = failure.destination { failure.destination = .sink(output) }
                diagnostic.kind = .fatal(failure)
            default: break
            }
            throw diagnostic
        } catch var error as RuntimeError {
            if case .standard = error.destination { error.destination = .sink(output) }
            throw error
        } catch var fatal as FatalError {
            if case .standard = fatal.error.destination { fatal.error.destination = .sink(output) }
            throw fatal
        }
    }

    // MARK: Values

    /// A global of the script: what `name` is bound to, if anything. Setting one makes it a
    /// constant for scripts to read.
    public subscript(name: String) -> Value? {
        get { withMainTask { lookup(name)?.value } }
        set {
            withMainTask {
                guard let newValue else {
                    scopes[1].bindings[name] = nil
                    return
                }
                scopes[1].bindings[name] = Binding(value: newValue, mutable: false)
            }
        }
    }

    /// A member of a value as a script reads it: `value(of: "columns", in: type)` is
    /// `Type.columns`.
    public func value(forMember member: String, of value: Value) throws(Diagnostic) -> Value {
        do {
            return try withMainTask { try self.member(member, of: value) }
        } catch {
            throw Diagnostic.of(error)
        }
    }

    /// Calls a function by name, or a method of `receiver`, as a script's call with these arguments
    /// would: the overload is chosen by the labels and the values given, and what is left out takes
    /// its default. A struct or enum type given as the receiver calls its static members and
    /// initializers (`call("init", on: type)`). From a host function it runs in the calling
    /// script's task; from outside, as the main one.
    @discardableResult
    public func call(
        _ name: String,
        on receiver: Value? = nil,
        arguments: [(label: String?, value: Value)] = []
    ) throws(Diagnostic) -> Value {
        let written = arguments.map { Argument(label: $0.label, value: .literal($0.value)) }
        do {
            return try inCurrentTask { () throws -> Value in
                // A Swift type's method by that name, when arguments are given: `count { … }` is a
                // method, not the property `count`. Where the prelude has a sequence method of the
                // name too, Swift's wins if it takes these arguments, as it does when a script is
                // checked.
                if let receiver, let methods = bridgedMethods(name, of: receiver),
                    !arguments.isEmpty || sequenceMethods[name] != nil
                {
                    var fits = true
                    if sequenceMethods[name] != nil,
                        case .function(let set as OverloadSet) = methods
                    {
                        fits = set.candidates.contains { (try? self.bind(written, to: $0)) != nil }
                    }
                    if fits { return try self.evaluate(.call(.literal(methods), written)) }
                }
                let callee: Expr = receiver.map { .member(.literal($0), name) } ?? .variable(name)
                return try self.evaluate(.call(callee, written))
            }
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
    /// result convert as SwiitKit's `ScriptConvertible` says, and a script
    /// sees an ordinary function: `labels` are its argument labels (`nil`
    /// or missing for none), and a wrong argument is the usual type error.
    public func register<each Argument: ScriptConvertible, Result: ScriptConvertible>(
        _ name: String,
        labels: [String?] = [],
        throwing: Bool = false,
        _ body: @escaping @Sendable (repeat each Argument) throws -> Result
    ) {
        install(
            name,
            labels: labels,
            throwing: throwing,
            returns: Result.scriptType,
            enums: Result.swiitEnums,
            parameterTypes: Self.types(repeat (each Argument).self)
        ) { arguments in
            var index = 0
            func next() -> Value {
                defer { index += 1 }
                return arguments[index]
            }
            return try body(repeat try (each Argument)(next())).value
        }
    }

    /// As above, for a closure that returns nothing.
    public func register<each Argument: ScriptConvertible>(
        _ name: String,
        labels: [String?] = [],
        throwing: Bool = false,
        _ body: @escaping @Sendable (repeat each Argument) throws -> Void
    ) {
        install(
            name,
            labels: labels,
            throwing: throwing,
            returns: nil,
            enums: [],
            parameterTypes: Self.types(repeat (each Argument).self)
        ) { arguments in
            var index = 0
            func next() -> Value {
                defer { index += 1 }
                return arguments[index]
            }
            try body(repeat try (each Argument)(next()))
            return .nothing
        }
    }

    private static func types<each Argument: ScriptConvertible>(
        _: repeat (each Argument).Type
    ) -> [(ScriptType, [Value.EnumCase.Enumeration])] {
        var types: [(ScriptType, [Value.EnumCase.Enumeration])] = []
        func add<T: ScriptConvertible>(_: T.Type) { types.append((T.scriptType, T.swiitEnums)) }
        repeat add((each Argument).self)
        return types
    }

    private func install(
        _ name: String,
        labels: [String?],
        throwing: Bool,
        returns: ScriptType?,
        enums: [Value.EnumCase.Enumeration],
        parameterTypes: [(ScriptType, [Value.EnumCase.Enumeration])],
        call: @escaping @Sendable ([Value]) throws -> Value
    ) {
        let parameters = parameterTypes.enumerated()
            .map { index, entry in
                let label = labels.indices.contains(index) ? labels[index] : nil
                return Symbol.Parameter(
                    label: label,
                    name: label ?? "argument\(index)",
                    type: entry.0
                )
            }
        let names = parameters.map(\.name)
        let function = hostFunction(
            HostFunction(
                name: name,
                parameters: parameters,
                returnType: returns,
                isThrowing: throwing,
                call: { arguments in try call(names.map { arguments[$0] ?? .nothing }) }
            )
        )
        for type in parameterTypes.flatMap(\.1) + enums {
            scopes[1].bindings[type.name] = Binding(value: .object(type), mutable: false)
        }
        scopes[1].declare(function, named: name)
    }

    // MARK: Running

    /// Runs source and gives the value of its last statement if that is an expression that ran
    /// (nothing otherwise). Runs on a thread with a large stack. Declarations and values stay for
    /// the next call.
    ///
    /// A prompt or a script runner passes the closures:
    ///
    /// - `onValue` is told the value of each of the program's own expression statements as it
    ///   runs (not those in blocks, like the body of a `for`: use `print` for those), except a bare
    ///   `true` or `false`, with the function the statement called when it is a call: its
    ///   `attributes` say, for one, that Swift lets its result go (`@discardableResult`). The last
    ///   one is told too, and given back as well.
    /// - `onError` is told of a run-time error in a statement, and says whether to go on with the
    ///   next one (a script reports an error and carries on); without it, the first stops the run.
    ///   A stop, a limit and an `Unwinding` error always end it.
    /// - `completion` runs after the last statement and before the program's own top-level
    ///   `defer`s, which run when it is all over.
    ///
    /// A mistake in the program's types or syntax is found before any statement runs.
    @discardableResult
    public func evaluate(
        _ source: String,
        onValue: ((_ value: Value, _ callee: Symbol?) throws -> Void)? = nil,
        onError: ((Diagnostic) -> Bool)? = nil,
        completion: (() -> Void)? = nil
    ) throws(Diagnostic) -> Value {
        try evaluate(
            source,
            onValue: onValue,
            onError: onError,
            completion: completion,
            alreadyCancelled: { false }
        )
    }

    /// `alreadyCancelled` is asked once the run has started afresh, so a request made before that
    /// is not lost.
    private func evaluate(
        _ source: String,
        onValue: ((_ value: Value, _ callee: Symbol?) throws -> Void)?,
        onError: ((Diagnostic) -> Bool)?,
        completion: (() -> Void)?,
        alreadyCancelled: @escaping () -> Bool
    ) throws(Diagnostic) -> Value {
        // Nothing else runs on this interpreter meanwhile.
        nonisolated(unsafe) let interpreter = self  // safe: runs holding the interpreter lock
        nonisolated(unsafe) let onValue = onValue  // safe: runs holding the interpreter lock
        nonisolated(unsafe) let onError = onError  // safe: runs holding the interpreter lock
        nonisolated(unsafe) let completion = completion  // safe: runs holding the interpreter lock
        let observer: ValueObserver? = onValue
        do {
            // From a host function, in a run already, it carries on where it is. Otherwise Swiit
            // code runs holding the lock, which a task it starts waits for.
            if interpreter.lock.isHeldByCurrentThread {
                return try interpreter.runSource(
                    source,
                    observer: observer,
                    onError: onError,
                    finish: completion,
                    nested: true,
                    alreadyCancelled: alreadyCancelled
                )
            }
            return try onLargeStack {
                try interpreter.withMainTask {
                    try interpreter.runSource(
                        source,
                        observer: observer,
                        onError: onError,
                        finish: completion,
                        alreadyCancelled: alreadyCancelled
                    )
                }
            }
        } catch {
            throw Diagnostic.of(error)
        }
    }

    /// As `evaluate`, on a thread of the interpreter's own, and cancelled when the calling task is.
    /// The closures run on that thread.
    @discardableResult
    public func evaluate(
        _ source: String,
        onValue: ((_ value: Value, _ callee: Symbol?) throws -> Void)? = nil,
        onError: ((Diagnostic) -> Bool)? = nil,
        completion: (() -> Void)? = nil
    ) async throws(Diagnostic) -> Value {
        let cancelled = CancelFlag()
        nonisolated(unsafe) let onValue = onValue  // safe: runs holding the interpreter lock
        nonisolated(unsafe) let onError = onError  // safe: runs holding the interpreter lock
        nonisolated(unsafe) let completion = completion  // safe: runs holding the interpreter lock
        let outcome: Result<Value, Diagnostic> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                nonisolated(unsafe) let interpreter = self  // safe: runs holding the interpreter lock
                startLargeStackThread {
                    continuation.resume(
                        returning: Result { () throws(Diagnostic) -> Value in
                            try interpreter.evaluate(
                                source,
                                onValue: onValue,
                                onError: onError,
                                completion: completion,
                                alreadyCancelled: { cancelled.isSet }
                            )
                        }
                    )
                }
            }
        } onCancel: {
            cancelled.set()
            cancel()
        }
        return try outcome.get()
    }

    private func runSource(
        _ source: String,
        observer: ValueObserver? = nil,
        onError: ((Diagnostic) -> Bool)? = nil,
        finish: (() -> Void)? = nil,
        nested: Bool = false,
        alreadyCancelled: () -> Bool
    ) throws -> Value {
        // A run begun from a host function inside one carries on under the limits and the stop of
        // the one it is in.
        if !nested {
            steps = 0
            outputCounter.reset()
            deadline = limits.timeLimit.map { ContinuousClock.now + $0 }
            cancellation.clear()
            if alreadyCancelled() { cancellation.request() }
        }
        let program: Program
        switch parse(source) {
        case .failure(let error):
            throw Diagnostic(
                kind: .syntax(isIncomplete: error.incomplete),
                message: error.description,
                range: error.range
            )
        case .success(let parsed): program = parsed
        }
        do {
            let checker = TypeChecker(interpreter: self)
            let checked = try checker.check(program)
            // What the program declared is typed as written for the next run: `var x: Int? = nil`
            // is an optional Int.
            staticTypes.merge(checker.declaredGlobals) { $1 }
            return try run(checked, observing: observer, onError: onError, finish: finish)
        } catch {
            throw Diagnostic.of(error)
        }
    }
}

/// Whether the task running an `async` evaluation has been cancelled, which the thread asks as it
/// starts.
private final class CancelFlag: Sendable {
    private let value = Mutex(false)
    var isSet: Bool { value.withLock { $0 } }
    func set() { value.withLock { $0 = true } }
}
