import Foundation

// The instructions that look a name up or leave a piece to the tree evaluator, and the rare ones of
// cells, inout arguments and ranges.

extension Interpreter {
    /// `executeMemberInstruction` for what looks a name up or leaves a piece to the tree evaluator, which
    /// first has the scope of `self` made in the frame of a method.
    func executeEvaluationInstruction(
        _ instruction: Instruction,
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
        case .conform(let dst, let src, let type):
            let value = stack.base[base + Int(src)]
            let expected = code.types[Int(type)]
            guard let conforming = conform(value, to: expected) else {
                throw RuntimeError("expected \(expected), not \(value.typeName)")
            }
            stack.base[base + Int(dst)] = conforming
        case .assignByName(let site, let value):
            ensureSelfScope(function, code, base: base, on: stack)
            var assignment = code.assignments[Int(site)]
            assignment.value = .literal(stack.base[base + Int(value)])
            try assign(assignment)
        case .iterationMismatch(let element):
            throw RuntimeError(
                "a \(stack.base[base + Int(element)].typeName) doesn't fit this 'for' pattern"
            )
        case .derefWeak(let register):
            let slot = base + Int(register)
            if case .object(let reference as WeakReference) = stack.base[slot].storage {
                stack.base[slot] = reference.target.map { .object($0) } ?? .nothing
            }
        case .makeClosure(let dst, let site):
            ensureSelfScope(function, code, base: base, on: stack)
            let made = try makeClosure(code.closures[Int(site)], stack.base + base)
            stack.base[base + Int(dst)] = made
        case .inoutOutputs(let first, let count):
            task.inoutOutputs = (0..<Int(count)).map { stack.base[base + Int(first) + $0] }
        case .takeInout(let dst, let index):
            let outputs = task.inoutOutputs
            stack.base[base + Int(dst)] =
                Int(index) < outputs.count ? outputs[Int(index)] : .nothing
        case .finishInout:
            task.inoutOutputs = []
        case .failInit(let register):
            if register == Register.max || stack.base[base + Int(register)] == .nothing {
                task.failedInit = true
            }
        default:
            preconditionFailure("not an evaluation instruction")
        }
    }
}
