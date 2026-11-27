import Foundation

// Running a piece of a compiled function on the tree evaluator, in the frame of the function.

extension Interpreter {
    /// Runs what the compiler left to the tree evaluator, over a frame holding the locals it
    /// mentions: each is moved out of its register into the frame (a collection is not copied that
    /// way, so changing it in place stays cheap), or shared when a closure keeps it in a cell, and
    /// moved back after, whatever happened.
    func runTree(_ node: TreeNode, base: Int, on stack: VMStack) throws -> Value {
        vmTreeRuns += 1
        let task = self.task
        let frame = task.spareFrames.popLast() ?? Frame(size: node.frameSize)
        frame.reset(size: node.frameSize)
        var moved: [Int] = []
        for local in node.locals {
            let index = base + Int(local.slot)
            if local.boxed, case .object(let object) = stack.base[index].storage,
                let cell = object as? Binding.Cell
            {
                frame.bind(
                    local.name,
                    Binding(cell: cell, mutable: local.mutable),
                    at: Int(local.slot)
                )
            } else {
                frame.bind(
                    local.name,
                    Binding(value: stack.base[index], mutable: local.mutable),
                    at: Int(local.slot)
                )
                stack.base[index] = .nothing
                moved.append(Int(local.slot))
            }
        }
        let saved = (task.frame, task.frameBase)
        task.frame = frame
        task.frameBase = task.scopes.count
        defer {
            for slot in moved {
                stack.base[base + slot] = frame.binding(at: slot)?.value ?? .nothing
            }
            frame.empty()
            task.spareFrames.append(frame)
            (task.frame, task.frameBase) = saved
        }
        switch node.source {
        case .expression(let expression): return try evaluate(expression)
        case .statement(let statement):
            try run(statement)
            return .nothing
        }
    }
}
