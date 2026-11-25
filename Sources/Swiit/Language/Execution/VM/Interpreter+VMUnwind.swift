import Foundation

// Leaving frames when an error is raised in them (`Docs/vm.md`).

extension Interpreter {
    /// The frames an error leaves, innermost first, each reporting it as the tree evaluator does: the
    /// statement it was in, and the call it ended. A frame that has code for it (a `catch`, a `defer`,
    /// a `try?`) goes on there instead, with the cursor at it; an error nothing in the run handles is
    /// thrown.
    func unwind(
        _ failure: Error,
        _ cursor: inout VMCursor,
        entryDepth: Int,
        on stack: VMStack
    ) throws {
        let task = self.task
        var error = failure
        while true {
            let (function, code) = (cursor.function, cursor.code)
            // An error caught inside an expression has not left the statement.
            let guarded = handler(in: code, at: cursor.pc - 1, for: error)
            if !code.isImplicitReturn, guarded?.isExpression != true,
                var runtime = error as? RuntimeError
            {
                if cursor.statement >= 0, let range = code.ranges[Int(cursor.statement)] {
                    if runtime.range == nil {
                        runtime.range = range
                    } else if let last = runtime.calls.indices.last,
                        runtime.calls[last].site == nil
                    {
                        runtime.calls[last].site = range
                    }
                }
                error = runtime
            }
            if let handler = guarded {
                if handler.keepsError { stack.caught.append(error) }
                if let register = handler.register, let runtime = error as? RuntimeError {
                    stack.base[cursor.base + Int(register)] = runtime.value
                }
                cursor.pc = handler.target
                return
            }
            if !code.isImplicitReturn, !code.isProgram, var runtime = error as? RuntimeError {
                runtime.calls.append(
                    RuntimeError.Call(function: function.name ?? "a closure", site: nil)
                )
                error = runtime
            }
            leaveFrame(function, code, base: cursor.base, stack)
            guard stack.callers.count > entryDepth else { throw error }
            let caller = stack.callers.removeLast()
            if caller.isMethod { abandonMethod(stack.methodExits.removeLast(), on: stack) }
            cursor = VMCursor(
                function: caller.function,
                code: caller.code,
                base: caller.base,
                pc: caller.pc,
                statement: caller.statement
            )
            if let own = caller.scopes {
                task.scopes = own
            } else {
                setScopes(of: caller.function, from: function, task)
            }
            stack.top = cursor.base + cursor.code.frameSize
        }
    }

    /// The code that deals with an error raised at instruction `pc` of `code`: the innermost handler
    /// whose stretch has it and that catches this kind of error.
    func handler(in code: Code, at pc: Int, for error: Error) -> Handler? {
        for handler in code.handlers.reversed() where handler.start <= pc && pc < handler.end {
            switch handler.catches {
            case .everything: return handler
            case .runtimeErrors: if error is RuntimeError { return handler }
            }
        }
        return nil
    }
}
