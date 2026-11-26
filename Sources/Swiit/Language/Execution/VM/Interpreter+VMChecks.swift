import Foundation

// What the loop checks as it goes: the stop request and the limits at each step, and the arguments of a call.

extension Interpreter {
    /// The arguments at `argumentBase` against the kinds the callee's parameters take, which only a
    /// call that gets one wrong does more than look at.
    @inline(__always)
    func checkKinds(
        _ callee: Function,
        _ calleeCode: Code,
        at argumentBase: Int,
        on stack: VMStack
    ) throws {
        let kinds = calleeCode.kindTable
        for index in 0..<calleeCode.parameterCount
        where !kinds[index].accepts(at: stack.base + argumentBase + index) {
            try checkArguments(of: callee, calleeCode, at: argumentBase, on: stack)
            return
        }
    }

    /// `checkInterrupt` for the loop, which has the task and its run in hand.
    @inline(__always)
    func tick(_ stop: UnsafeMutablePointer<Int32>, _ run: RunState) throws {
        if hasPendingDeinits { runPendingDeinits() }
        if stop.pointee != 0 { throw Cancelled() }
        run.stepsUntilCheck -= 1
        if run.stepsUntilCheck <= 0 { try checkLimits() }
    }
}
