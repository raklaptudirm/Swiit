import Foundation

/// What one run counts and is bounded by: its limits, the steps it has taken, when it must end and
/// where the output stood when it began. The run's root task holds it, and the tasks the run starts
/// share it, so they spend one budget. Another run on the same interpreter has its own.
///
/// Touched only holding the interpreter lock.
final class RunState {
    var limits: Interpreter.Limits {
        didSet { maxCallDepth = limits.maxCallDepth }
    }
    /// `limits.maxCallDepth`, kept apart so that a call does not copy the limits to read it.
    @exclusivity(unchecked) private(set) var maxCallDepth: Int
    /// The steps taken before the window `stepsUntilCheck` counts down began.
    private var stepsBeforeWindow = 0
    /// How many steps the window `stepsUntilCheck` counts down began with.
    private var window = 0
    /// Steps left before `checkLimits` runs again; nothing at the start of a run, so its first step
    /// checks. A step is one count down of this and nothing else, which is why `steps` is worked out
    /// from it.
    @exclusivity(unchecked) var stepsUntilCheck = 0

    /// The steps the run has taken.
    var steps: Int { stepsBeforeWindow + window - stepsUntilCheck }

    /// Begins counting `size` steps to the next check, from the steps taken so far.
    func startWindow(_ size: Int) {
        stepsBeforeWindow = steps
        window = size
        stepsUntilCheck = size
    }

    var deadline: ContinuousClock.Instant?
    /// The references reserved for the types the program being run declares at its top level, by
    /// name, until each declaration takes its own (`Interpreter.takeReservedRef`).
    var reservedRefs: [String: TypeRef] = [:]
    /// What the interpreter's output counter said as the run began: what the run has written is
    /// what the counter says beyond it.
    let outputAtStart: Int

    init(limits: Interpreter.Limits, outputAtStart: Int = 0) {
        self.limits = limits
        maxCallDepth = limits.maxCallDepth
        self.outputAtStart = outputAtStart
        deadline = limits.timeLimit.map { ContinuousClock.now + $0 }
    }
}
