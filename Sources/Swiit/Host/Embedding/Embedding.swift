import Foundation
import SwishKit

// The embedding API (Docs/Design/embedding.md): make an interpreter, give it
// functions and values, run source, and get a value or a diagnostic back.

/// What went wrong in a run, as a value: its kind, the message the shell
/// would print, and the line when the checker knows it.
public struct Diagnostic: Error, CustomStringConvertible, Equatable, Sendable {
    public enum Kind: Sendable { case syntax, type, runtime, limit, cancelled }

    public var kind: Kind
    public var message: String
    /// 1-based, for a type error in a multi-line program.
    public var line: Int?

    public init(kind: Kind, message: String, line: Int? = nil) {
        self.kind = kind
        self.message = message
        self.line = line
    }

    public var description: String { line.map { "line \($0): \(message)" } ?? message }
}

/// What bounds a run. Each is checked as the script runs; a script that hits
/// one stops with a `.limit` diagnostic, which it can't catch. Memory isn't
/// limited: a script that builds a huge list is bounded only by steps and time.
public struct Limits: Sendable {
    /// Statements and calls. Nil is no limit.
    public var steps: Int?
    /// Nested Swish function calls.
    public var depth: Int
    public var time: Duration?
    /// Bytes written to the host's output and error.
    public var output: Int?

    public init(steps: Int? = nil, depth: Int = 10_000, time: Duration? = nil, output: Int? = nil) {
        self.steps = steps
        self.depth = depth
        self.time = time
        self.output = output
    }
}

@_spi(Shell) public struct LimitExceeded: Error, CustomStringConvertible {
    @_spi(Shell) public let description: String
    @_spi(Shell) public init(_ description: String) { self.description = description }
}

@_spi(Shell) public struct Cancelled: Error {}

/// Bytes written so far, for the output limit.
@_spi(Shell) public final class OutputCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @_spi(Shell) public init() {}

    @_spi(Shell) public var written: Int { lock.withLock { count } }
    @_spi(Shell) public func add(_ bytes: Int) { lock.withLock { count += bytes } }
    @_spi(Shell) public func reset() { lock.withLock { count = 0 } }
}

/// A request to stop, from any thread.
@_spi(Shell) public final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false

    @_spi(Shell) public init() {}

    @_spi(Shell) public var isSet: Bool { lock.withLock { set } }
    @_spi(Shell) public func request() { lock.withLock { set = true } }
    @_spi(Shell) public func clear() { lock.withLock { set = false } }
}

extension Interpreter {
    /// An interpreter with Swift's syntax, the standard library and nothing
    /// else: no commands, no environment, no files. What a script can name
    /// is what the host registers.
    public convenience init(host: SwishHost = SwishHost(), limits: Limits = Limits()) {
        let counter = OutputCounter()
        func counted(_ sink: OutputSink) -> OutputSink {
            OutputSink(write: { counter.add($0.utf8.count); return sink.write($0) }, traits: sink.traits)
        }
        self.init(host: SwishHost(output: counted(host.output), error: counted(host.error), interrupt: host.interrupt),
                  shellLayer: nil,
                  outputCounter: counter)
        self.limits = limits
        installBuiltinFunctions()
    }

    /// `print("a", 1)`: its arguments, as interpolation shows them, separated
    /// by spaces, then a newline, to the host's output. The one way a script
    /// speaks, since a bare value gives nothing here.
    @_spi(Shell) public func installPrint() {
        nonisolated(unsafe) let interpreter = self
        let print = hostFunction(ExportedFunction(
            name: "print", summary: "Writes its arguments to the output, separated by spaces, then a newline.",
            parameters: [ExportedParameter(label: nil, name: "items", type: .any, variadic: true)], returnType: nil,
            call: { arguments in
                guard case .list(let items)? = arguments["items"] else { return .nothing }
                let line = items.map { item -> String in
                    if case .string(let text) = item { return text }
                    return "\(item)"
                }.joined(separator: " ")
                interpreter.host.output.write(line + "\n")
                return .nothing
            }
        ))
        scopes[0].declare(print, named: "print")
    }

    /// Asks a run in progress to stop, from any thread. It ends with a
    /// `.cancelled` diagnostic; the next `eval` starts afresh.
    public func cancel() { cancellation.request() }

    // MARK: Values

    /// Binds `name` to a value, for scripts to read.
    public func set(_ name: String, _ value: Value) {
        scopes[1].bindings[name] = Binding(value: value, mutable: false)
    }

    /// Binds `name` to anything `Encodable`: a record, a list, a string.
    public func set<T: Encodable>(_ name: String, _ value: T) throws {
        set(name, try ValueEncoder().encode(value))
    }

    /// What `name` is bound to, if anything.
    public func get(_ name: String) -> Value? {
        lookup(name)?.value
    }

    // MARK: Functions

    /// Makes a Swift closure a function scripts can call. Its parameters and
    /// result convert as SwishKit's `SwishConvertible` says, and a script
    /// sees an ordinary function: `labels` are its argument labels (`nil`
    /// or missing for none), and a wrong argument is the usual type error.
    public func register<each Argument: SwishConvertible, Result: SwishConvertible>(
        _ name: String, labels: [String?] = [], throwing: Bool = false,
        _ body: @escaping @Sendable (repeat each Argument) throws -> Result
    ) {
        install(name, labels: labels, throwing: throwing, returns: Result.swishType, enums: Result.swishEnums,
                parameterTypes: Self.types(repeat (each Argument).self)) { arguments in
            var index = 0
            func next() -> Value {
                defer { index += 1 }
                return arguments[index]
            }
            return try body(repeat try (each Argument)(swishValue: next())).swishValue
        }
    }

    /// As above, for a closure that returns nothing.
    public func register<each Argument: SwishConvertible>(
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
            try body(repeat try (each Argument)(swishValue: next()))
            return .nothing
        }
    }

    private static func types<each Argument: SwishConvertible>(_: repeat (each Argument).Type) -> [(SwishType, [EnumType])] {
        var types: [(SwishType, [EnumType])] = []
        func add<T: SwishConvertible>(_: T.Type) { types.append((T.swishType, T.swishEnums)) }
        repeat add((each Argument).self)
        return types
    }

    private func install(
        _ name: String, labels: [String?], throwing: Bool, returns: SwishType?, enums: [EnumType],
        parameterTypes: [(SwishType, [EnumType])], call: @escaping @Sendable ([Value]) throws -> Value
    ) {
        let parameters = parameterTypes.enumerated().map { index, entry in
            let label = labels.indices.contains(index) ? labels[index] : nil
            return ExportedParameter(label: label, name: label ?? "argument\(index)", type: entry.0, enums: entry.1)
        }
        let names = parameters.map(\.name)
        let function = hostFunction(ExportedFunction(
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
    public func eval(_ source: String) throws -> Value {
        // Nothing else runs on this interpreter meanwhile.
        nonisolated(unsafe) let interpreter = self
        do {
            return try onLargeStack { try interpreter.evaluate(source) }
        } catch let diagnostic as Diagnostic {
            throw diagnostic
        } catch {
            throw Diagnostic(kind: .runtime, message: "\(error)")
        }
    }

    private func evaluate(_ source: String) throws -> Value {
        steps = 0
        outputCounter.reset()
        deadline = limits.time.map { ContinuousClock.now + $0 }
        cancellation.clear()
        let program: Program
        switch parse(source) {
        case .failure(let error): throw Diagnostic(kind: .syntax, message: error.description)
        case .success(let parsed): program = parsed
        }
        do {
            var checked = try TypeChecker(interpreter: self).check(program)
            var last: Expr?
            if case .chain(let chain)? = checked.statements.last, chain.links.isEmpty, case .expression(let expr) = chain.first {
                last = expr
                checked.statements.removeLast()
                if checked.lines.count > checked.statements.count { checked.lines.removeLast() }
            }
            _ = try run(checked)
            return try last.map { try evaluate($0) } ?? .nothing
        } catch let error as TypeError {
            throw Diagnostic(kind: .type, message: error.message, line: error.line)
        } catch let error as RuntimeError {
            throw Diagnostic(kind: .runtime, message: error.description)
        } catch let reported as AlreadyReported {
            throw Diagnostic(kind: .runtime, message: reported.error.description)
        } catch let fatal as FatalError {
            throw Diagnostic(kind: .runtime, message: fatal.error.description)
        } catch let limit as LimitExceeded {
            throw Diagnostic(kind: .limit, message: limit.description)
        } catch is Cancelled {
            throw Diagnostic(kind: .cancelled, message: "cancelled")
        } catch is Interrupted {
            throw Diagnostic(kind: .cancelled, message: "interrupted")
        }
    }
}
