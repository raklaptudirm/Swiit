import Foundation

// Executing the instructions of the blocks that declare functions and types by name.

extension Interpreter {
    func executeDeclarations(
        _ instruction: Instruction.Declarations,
        _ cursor: inout VMCursor,
        _ stack: VMStack
    ) throws {
        let (function, code, base) = (cursor.function, cursor.code, cursor.base)
        switch instruction {
        case .markScopes(let dst):
            // A method's `self` is bound in a scope below those its blocks open, made once.
            ensureSelfScope(function, code, base: base, on: stack)
            stack.base[base + Int(dst)] = .int(task.scopes.count)
        case .openScope:
            task.scopes.append(Scope())
        case .closeScope:
            task.scopes.removeLast()
        case .declareFunction(let site):
            bindDeclared(try makeClosure(code.closures[Int(site)], stack.base + base))
        case .loadCallee(let dst):
            stack.base[base + Int(dst)] = .function(function)
        }
    }

    /// Brings the task's scopes back to those a frame of `code` began with, when its blocks declare
    /// by name: as it ends, and when an error is caught in it (`Handler.Scopes`).
    func restoreScopes(of code: Code, base: Int, opening depth: Int, on stack: VMStack) {
        guard let mark = code.scopeMark,
            case .int(let count) = stack.base[base + Int(mark)].storage
        else { return }
        let kept = count + depth
        if task.scopes.count > kept { task.scopes.removeLast(task.scopes.count - kept) }
    }
}
