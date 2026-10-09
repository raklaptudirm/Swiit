import Foundation
import SwishKit

/// The language: its scopes, what the checker remembers between entries, and
/// the evaluator (the `Interpreter+…` files). It knows nothing of the
/// terminal, processes or jobs: it reaches the world through its `host`, and
/// the shell's constructs through a `shellLayer`, which is internal and
/// temporary (Docs/Design/boundaries.md). The shell owns one.
public final class Interpreter {
    /// How this interpreter is run: where its output goes, how to tell it to stop.
    @_spi(Shell) public var host: SwishHost

    /// What the core still can't do without the shell: the environment,
    /// commands, jobs. Nil for an embedder, which is refused plainly.
    @_spi(Shell) public var shellLayer: ShellLayer?
    /// What runs this interpreter, if it is more than an embedder's call: the
    /// shell, whose nodes reach it from here. Weak, as the owner holds the
    /// interpreter.
    @_spi(Shell) public weak var owner: AnyObject?
    /// The members, by name, of the host's object types that Swift doesn't
    /// declare (the shell's `Job`), for the checker.
    /// The bridged libraries installed: the core's, and the host's.
    @_spi(Shell) public var libraries: [Library] = []
    /// The types of dynamic objects' members (`DynamicObject`), by type name.
    @_spi(Shell) public var dynamicTypes: [String: DynamicType] = [:]
    /// How values lay out as tables, which only a host that shows them has
    /// (the shell installs it). Library functions that format are lent this.
    @_spi(Shell) public var displayRegistryProvider: () -> DisplayRegistry = { DisplayRegistry() }
    /// What `await` waits for, if the host has anything to wait for.
    @_spi(Shell) public var awaiting: Awaiting?
    @_spi(Shell) public var objectMembers: [String: [String: TypeAnnotation]] = [:]

    /// Variable scopes, innermost last. The outermost holds the builtin
    /// functions, so a `func` at the prompt shadows one rather than
    /// overloading it.
    @_spi(Shell) public var scopes = [Scope(), Scope()]
    /// How many Swish function calls are in progress.
    @_spi(Shell) public var callDepth = 0
    /// Each enum's associated value types, by case, for checking them.
    @_spi(Shell) public var enumPayloadTypes: [ObjectIdentifier: [String: [TypeAnnotation]]] = [:]
    /// The protocols each enum declares.
    @_spi(Shell) public var enumConformances: [ObjectIdentifier: [String]] = [:]
    /// The return types of the functions being run, innermost last, so a
    /// returned `.case` knows its enum.
    @_spi(Shell) public var returnTypes: [TypeAnnotation?] = []
    /// Methods every sequence has, like `sorted` and `filter`.
    @_spi(Shell) public var sequenceMethods: [String: OverloadSet] = [:]
    /// The declared types of globals, from entries already checked, so a
    /// later one knows `let xs: [Int] = []` is an [Int].
    @_spi(Shell) public var staticTypes: [String: TypeAnnotation] = [:]
    /// Per-item errors reported so far, like a file `ls` couldn't read.
    @_spi(Shell) public var itemErrorCount = 0
    /// Syntax added to Swift's, which its owner supplies (the shell's). Nil is
    /// Swift alone.
    @_spi(Shell) public var syntax: (any SyntaxPlugin)?
    /// The file being run, for `#filePath`; nil at the prompt.
    @_spi(Shell) public var file: String?
    /// The status the last statement gave.
    @_spi(Shell) public var lastStatus: Int32 = 0
    /// The status the last signal-killed command gave, to tell 130 from ^C
    /// apart from a command that exited with 130.
    @_spi(Shell) public var lastSignalStatus: Int32?

    /// What bounds a run (steps, depth, time, output), counted from the start
    /// of each `eval`.
    @_spi(Shell) public var limits = Limits()
    @_spi(Shell) public var steps = 0
    @_spi(Shell) public var deadline: ContinuousClock.Instant?
    /// What a run has written, against `limits.output`.
    @_spi(Shell) public let outputCounter: OutputCounter
    /// Asks a run to stop, from any thread.
    @_spi(Shell) public let cancellation = Cancellation()

    @_spi(Shell) public init(host: SwishHost, shellLayer: ShellLayer?, outputCounter: OutputCounter = OutputCounter()) {
        self.host = host
        self.shellLayer = shellLayer
        self.outputCounter = outputCounter
    }
}

extension Interpreter {
    /// Reports an error, to wherever standard error is redirected.
    @_spi(Shell) public func report(_ message: String) {
        let styled = host.error.traits().styled
        if message.hasPrefix("error: ") {
            host.error.write("swish: error:".styled(DisplayStyle.error, styled) + message.dropFirst(6) + "\n")
        } else {
            host.error.write("swish:".styled(DisplayStyle.error, styled) + " \(message)\n")
        }
    }

    /// Reports a problem with one item, like a file `ls` couldn't read,
    /// without stopping; the statement's status becomes a failure.
    @_spi(Shell) public func reportItemError(_ message: String) {
        report(message)
        itemErrorCount += 1
    }
}

extension Interpreter {
    /// Parses a program, knowing the names already declared.
    @_spi(Shell) public func parse(_ source: String) -> Result<Program, SyntaxError> {
        do {
            return .success(try Parser.parse(source, bound: globalNames(), plugin: syntax))
        } catch {
            return .failure(error)
        }
    }

    /// Names the parser should know: builtins and globals, as variables or functions.
    @_spi(Shell) public func globalNames() -> [String: NameKind] {
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
