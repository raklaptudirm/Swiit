import Foundation

// Handing an instruction that is not on the common path of the loop to the executor of its family.

extension Interpreter {
    /// Runs an instruction the loop hands off. It changes registers and `pc`, never the frame. Inlined
    /// into the loop, so that an instruction reaches its family's executor with one call.
    @inline(__always)
    func executeHandedOff(
        _ instruction: Instruction,
        _ cursor: inout VMCursor,
        _ stack: VMStack
    ) throws {
        switch instruction {
        case .members(let members): try executeMembers(members, &cursor, stack)
        case .collections(let collections): try executeCollections(collections, &cursor, stack)
        case .conversions(let conversions): try executeConversions(conversions, &cursor, stack)
        case .patterns(let patterns): try executePatterns(patterns, &cursor, stack)
        case .iteration(let iteration): try executeIteration(iteration, &cursor, stack)
        case .errors(let errors): try executeErrors(errors, &cursor, stack)
        case .fallback(let fallback): try executeFallback(fallback, &cursor, stack)
        case .captures(let captures): try executeCaptures(captures, &cursor, stack)
        case .calls(let calls): try executeCalls(calls, &cursor, stack)
        case .globals(let globals): try executeGlobals(globals, &cursor, stack)
        default: preconditionFailure("an instruction of the loop's own")
        }
    }
}
