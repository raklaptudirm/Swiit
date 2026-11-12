import Foundation
import SwiftSyntax
import Synchronization

// Evaluating source: all of it, or a statement at a time with observers.

extension Interpreter {
    /// Runs source and gives the value of its last statement if that is an expression that ran
    /// (nothing otherwise). `limits` bound this run alone, in place of the interpreter's own. Runs on a thread with a large stack. Declarations and values stay for
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
        limits: Limits? = nil,
        onValue: ((_ value: Value, _ callee: Symbol?) throws -> Void)? = nil,
        onError: ((Diagnostic) -> Bool)? = nil,
        completion: (() -> Void)? = nil
    ) throws(Diagnostic) -> Value {
        try evaluate(
            source,
            limits: limits,
            onValue: onValue,
            onError: onError,
            completion: completion,
            alreadyCancelled: { false }
        )
    }

    // swiftlint:disable function_parameter_count - it threads one state through; splitting it is item 17 of Docs/agenda.md
    /// `alreadyCancelled` is asked once the run has started afresh, so a request made before that
    /// is not lost.
    private func evaluate(
        _ source: String,
        limits: Limits?,
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
                    limits: limits,
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
                        limits: limits,
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
    // swiftlint:enable function_parameter_count

    /// As `evaluate`, on a thread of the interpreter's own, and cancelled when the calling task is.
    /// The closures run on that thread.
    @discardableResult
    public func evaluate(
        _ source: String,
        limits: Limits? = nil,
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
                // safe: runs holding the interpreter lock
                nonisolated(unsafe) let interpreter = self
                startLargeStackThread {
                    continuation.resume(
                        returning: Result { () throws(Diagnostic) -> Value in
                            try interpreter.evaluate(
                                source,
                                limits: limits,
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

    /// What a run starts from: no steps taken, no output counted, the time limit counting from now
    /// and no stop asked for (but one asked before it began, which `alreadyCancelled` says).
    func beginRun(alreadyCancelled: () -> Bool = { false }) {
        steps = 0
        stepsUntilCheck = 0
        outputCounter.reset()
        deadline = limits.timeLimit.map { ContinuousClock.now + $0 }
        cancellation.clear()
        if alreadyCancelled() { cancellation.request() }
    }

    private func runSource(
        _ source: String,
        limits runLimits: Limits? = nil,
        observer: ValueObserver? = nil,
        onError: ((Diagnostic) -> Bool)? = nil,
        finish: (() -> Void)? = nil,
        nested: Bool = false,
        alreadyCancelled: () -> Bool
    ) throws -> Value {
        // A run begun from a host function inside one carries on under the limits and the stop of
        // the one it is in.
        let outerLimits = limits
        defer { if !nested { limits = outerLimits } }
        if !nested {
            if let runLimits { limits = runLimits }
            beginRun(alreadyCancelled: alreadyCancelled)
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
            checkerMemory.globalTypes.merge(checker.declaredGlobals) { $1 }
            // The locals of its blocks, functions and closures in frames.
            let resolved = FrameResolver.resolve(program: checked)
            return try withFrame(size: resolved.frameSize) {
                try run(resolved, observing: observer, onError: onError, finish: finish)
            }
        } catch {
            throw Diagnostic.of(error)
        }
    }
}
