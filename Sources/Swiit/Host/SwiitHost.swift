
/// Where one of the interpreter's output streams goes.
public struct OutputSink: Sendable {
    /// What a stream can show, so values are laid out for it: a terminal gets tables fitted to its width and in color, a
    /// file or a pipe gets every character, plain.
    public struct Traits: Sendable {
        public var isTerminal: Bool
        /// Its width in columns, when it has one.
        public var width: Int?
        /// Whether to color what's written to it.
        public var styled: Bool

        public static let plain = Traits(isTerminal: false, width: nil, styled: false)

        public init(isTerminal: Bool, width: Int? = nil, styled: Bool) {
            self.isTerminal = isTerminal
            self.width = width
            self.styled = styled
        }
    }

    private let send: @Sendable (String) -> Bool
    /// Asked each time, since where output goes can change while a script runs.
    public let traits: @Sendable () -> Traits

    /// `write` says whether the text went: false once the reader has gone, as
    /// with a closed pipe.
    public init(_ write: @escaping @Sendable (String) -> Bool) {
        send = write
        traits = { .plain }
    }

    /// `traits` is asked each time, since where output goes can change while a script runs. The closures are called safely
    /// by the host: only holding the interpreter's lock, or from its own thread.
    public init(write: @escaping (String) -> Bool, traits: @escaping () -> Traits) {
        // The shell's sinks write to the shell's own descriptors, from whichever thread holds the interpreter.
        let write = UncheckedSendable(write), traits = UncheckedSendable(traits)
        send = { write.value($0) }
        self.traits = { traits.value() }
    }

    /// Writes `text`; false once the reader has gone.
    @discardableResult
    public func write(_ text: String) -> Bool {
        send(text)
    }

    /// Output nobody reads.
    public static var discard: OutputSink { OutputSink({ _ in true }) }
}

/// Why the host asked the program to stop. The interpreter only carries it:
/// whoever asked reads it back from the `Interrupted` error. (The shell's is
/// the signal number, so it can end by that signal.)
@_spi(Layer) public struct StopReason: Sendable {
    public var code: Int32

    public init(code: Int32) {
        self.code = code
    }
}

extension Interpreter {
    /// How the interpreter is run: where its output goes and how to tell it to
    /// stop. This is all an embedder supplies: what a script can name (`env`,
    /// `jobs`, functions, types) is registered, not passed here. The defaults
    /// do nothing, so a host gives only what it wants.
    public struct Host: Sendable {
        public var output: OutputSink = .discard
        public var error: OutputSink = .discard
        /// Asked at each step: whether the run should stop.
        public var shouldStop: @Sendable () -> Bool {
            get { let interrupt = interrupt; return { interrupt() != nil } }
            set { interrupt = { newValue() ? StopReason(code: 0) : nil } }
        }

        /// What it calls itself where it reports an error, as in
        /// `swiit: error: …`: the program's name, for one that has its own.
        @_spi(Layer) public var name = "swiit"
        /// Asked at each step: a reason to stop, if there is one.
        @_spi(Layer) public var interrupt: @Sendable () -> StopReason? = { nil }
        /// Runs a task's body on a thread of its own, with a stack large enough
        /// for the interpreter's recursion; by default, one the core makes.
        @_spi(Layer) public var startThread: @Sendable (_ body: @escaping @Sendable () -> Void) -> Void = startLargeStackThread

        /// Made for each task a script starts (Swift's `Task { }`, `async let`): what the host keeps for it, as a shell keeps
        /// its output and status. Read back as `Interpreter.taskState` while that task runs.
        public var makeTaskState: @Sendable () -> AnyObject? = { nil }
        /// Told when the task running waits for another to end (`await`), with the state of the one awaited, before it does;
        /// what it gives back is called once the wait is over. A shell brings the awaited task forward meanwhile.
        public var willAwait: @Sendable (_ awaited: AnyObject?) -> () -> Void = { _ in {} }
        /// How a read of the host's input (`Interpreter.whileWaitingForInput`) waits for the running task's turn at it, as a
        /// shell's task in the background waits until it is awaited; then it runs the read, or doesn't, if the task is
        /// cancelled first. Without it a read runs at once.
        public var inputTurn: (@Sendable (_ read: () -> Void) -> Void)?

        public init(output: OutputSink = .discard, error: OutputSink = .discard, shouldStop: @escaping @Sendable () -> Bool = { false }) {
            self.output = output
            self.error = error
            self.shouldStop = shouldStop
        }

        @_spi(Layer) public init(name: String = "swiit", output: OutputSink = .discard, error: OutputSink = .discard,
                                 interrupt: @escaping () -> StopReason? = { nil },
                                 startThread: @escaping (_ body: @escaping @Sendable () -> Void) -> Void = startLargeStackThread) {
            let interrupt = UncheckedSendable(interrupt), startThread = UncheckedSendable(startThread)
            self.name = name
            self.output = output
            self.error = error
            self.interrupt = { interrupt.value() }
            self.startThread = { startThread.value($0) }
        }
    }
}

/// A closure the interpreter's owner promises is called safely: only holding the interpreter's lock, or from its own thread.
struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Internal name for the traits a stream has.
typealias StreamTraits = OutputSink.Traits
