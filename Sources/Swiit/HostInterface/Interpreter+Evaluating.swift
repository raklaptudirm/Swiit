import Foundation
import SwiftSyntax
import Synchronization

// Evaluating source: all of it, or a statement at a time with observers.

extension Interpreter {
    /// Runs `source` and returns the value of its last statement if that is an expression that ran, and
    /// nothing otherwise. `limits`, if given, replace the interpreter's own for this run. The run happens
    /// on a thread with a large stack, and declarations and values stay for the next call.
    ///
    /// A prompt or a script runner passes the closures:
    ///
    /// - `onValue` is told the value of each of the program's own expression statements as it runs, with
    ///   the function the statement called when it is a call (its `attributes` say whether Swift lets the
    ///   result go, `@discardableResult`). Statements inside blocks, such as the body of a `for`, are not
    ///   reported (use `print` for those), and neither is a bare `true` or `false`. The last one is also
    ///   returned.
    /// - `onError` is told of a run-time error in a statement, and says whether to go on with the next one
    ///   (a script reports an error and carries on). Without it, the first error stops the run. A stop, a
    ///   limit and an `Unwinding` error always end it.
    /// - `completion` runs after the last statement and before the program's own top-level `defer`s, which
    ///   run when it is all over.
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
            stopFlag: nil
        )
    }

    // swiftlint:disable function_parameter_count - it threads one state through; splitting it is item 25 of Docs/agenda.md
    /// `stopFlag` ties the run to a request to stop it that may be made before the run begins.
    private func evaluate(
        _ source: String,
        limits: Limits?,
        onValue: ((_ value: Value, _ callee: Symbol?) throws -> Void)?,
        onError: ((Diagnostic) -> Bool)?,
        completion: (() -> Void)?,
        stopFlag: CancelFlag?
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
                    nested: true
                )
            }
            return try onLargeStack {
                try interpreter.withRun(limits: limits, stopFlag: stopFlag) {
                    try interpreter.runSource(
                        source,
                        observer: observer,
                        onError: onError,
                        finish: completion
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
                                stopFlag: cancelled
                            )
                        }
                    )
                }
            }
        } onCancel: {
            cancelled.set()
        }
        return try outcome.get()
    }

    private func runSource(
        _ source: String,
        observer: ValueObserver? = nil,
        onError: ((Diagnostic) -> Bool)? = nil,
        finish: (() -> Void)? = nil,
        nested: Bool = false
    ) throws -> Value {
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

        // The types the program declares are named by the references reserved here as it is
        // checked, and take them as they are declared.
        let outerReserved = reservedRefs
        reservedRefs.merge(reservations(for: program)) { _, new in new }
        defer { reservedRefs = outerReserved }
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
