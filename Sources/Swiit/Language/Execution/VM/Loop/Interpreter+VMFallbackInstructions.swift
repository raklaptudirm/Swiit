import Foundation

// Executing the instructions that look a name up or leave a piece to the tree evaluator.

extension Interpreter {
    func executeFallback(
        _ instruction: Instruction.Fallback,
        _ cursor: inout VMCursor,
        _ stack: VMStack
    ) throws {
        let (function, code, base) = (cursor.function, cursor.code, cursor.base)
        switch instruction {
        case .loadVariable(let dst, let name):
            ensureSelfScope(function, code, base: base, on: stack)
            let value = try evaluate(.variable(code.names[Int(name)]))
            stack.base[base + Int(dst)] = value
        case .evaluate(let dst, let expression):
            ensureSelfScope(function, code, base: base, on: stack)
            let value = try evaluate(code.expressions[Int(expression)])
            stack.base[base + Int(dst)] = value
        case .evaluateTree(let dst, let node):
            ensureSelfScope(function, code, base: base, on: stack)
            let value = try runTree(code.trees[Int(node)], base: base, on: stack)
            stack.base[base + Int(dst)] = value
        case .runTree(let node):
            ensureSelfScope(function, code, base: base, on: stack)
            _ = try runTree(code.trees[Int(node)], base: base, on: stack)
        case .assignByName(let site, let value):
            ensureSelfScope(function, code, base: base, on: stack)
            var assignment = code.assignments[Int(site)]
            assignment.value = .literal(stack.base[base + Int(value)])
            try assign(assignment)
        }
    }
}
