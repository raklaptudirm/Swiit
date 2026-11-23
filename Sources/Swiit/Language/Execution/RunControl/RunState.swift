import Foundation

/// What one run counts and is bounded by: its limits, the steps it has taken, when it must end and
/// where the output stood when it began. The run's root task holds it, and the tasks the run starts
/// share it, so they spend one budget. Another run on the same interpreter has its own.
///
/// Touched only holding the interpreter lock.
final class RunState {
    var limits: Interpreter.Limits
    var steps = 0
    /// Steps left before `checkLimits` runs again; nothing at the start of a run, so its first step
    /// checks.
    var stepsUntilCheck = 0
    var deadline: ContinuousClock.Instant?
    /// The references reserved for the types the program being run declares at its top level, by
    /// name, until each declaration takes its own (`Interpreter.takeReservedRef`).
    var reservedRefs: [String: TypeRef] = [:]
    /// What the interpreter's output counter said as the run began: what the run has written is
    /// what the counter says beyond it.
    let outputAtStart: Int

    init(limits: Interpreter.Limits, outputAtStart: Int = 0) {
        self.limits = limits
        self.outputAtStart = outputAtStart
        deadline = limits.timeLimit.map { ContinuousClock.now + $0 }
    }
}
