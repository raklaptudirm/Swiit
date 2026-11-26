import Foundation

// Calls a native body makes into compiled code: a closure it was given, called from Swift (the closures
// a bridged member calls for each element, as `Value.Bridging.Callback` does).

extension Interpreter {
    /// The function a value is, and its code, when a native body can call it as the loop does: a
    /// compiled function or closure of the global scopes that changes none of its arguments and takes
    /// the arguments as they come (`Code.isPlain`). Nil where it is not that.
    func plainClosure(_ value: Value) -> (function: Function, code: Code)? {
        guard engine == .vm, case .function(let callable) = value.storage else { return nil }
        let function: Function
        if let single = callable as? Function {
            function = single
        } else if let set = callable as? OverloadSet, set.candidates.count == 1 {
            function = set.candidates[0]
        } else {
            return nil
        }
        guard function.inoutNames.isEmpty, let code = compiled(function), code.isPlain else {
            return nil
        }
        return (function, code)
    }

    /// A closure or function a native body calls with `arguments`, run by the VM from the values and not
    /// through a table of names. What `invoke` does, in the same steps; nil, with nothing done, where it
    /// is not a plain closure that takes this many arguments.
    func callPlainClosure(_ value: Value, _ arguments: [Value]) throws -> Value? {
        guard let target = plainClosure(value), target.function.parameters.count == arguments.count
        else { return nil }
        return try enterPlain(target.function, target.code, count: arguments.count) { base in
            for (index, argument) in arguments.enumerated() { base[index] = argument }
        }
    }

    /// `callPlainClosure` for one argument and for two, which make no array.
    func callPlain(_ function: Function, _ code: Code, _ first: Value) throws -> Value {
        try enterPlain(function, code, count: 1) { $0[0] = first }
    }

    func callPlain(
        _ function: Function,
        _ code: Code,
        _ first: Value,
        _ second: Value
    ) throws -> Value {
        try enterPlain(function, code, count: 2) {
            $0[0] = first
            $0[1] = second
        }
    }

    /// The call, once the function is found: the arguments are written where the parameters of the new
    /// frame will be, by `write`, which is given the first of them.
    @inline(__always)
    private func enterPlain(
        _ function: Function,
        _ code: Code,
        count: Int,
        _ write: (UnsafeMutablePointer<Value>) -> Void
    ) throws -> Value {
        let maxCallDepth = task.run.maxCallDepth
        guard task.callDepth < maxCallDepth else {
            throw RuntimeError("maximum call depth (\(maxCallDepth)) exceeded")
        }
        try checkInterrupt()
        defer { if task.lastCallee !== function { task.lastCallee = function } }
        let stack = task.vm
        let base = stack.top
        stack.ensure(base + max(code.frameSize, count))
        write(stack.base + base)
        try checkArguments(of: function, code, at: base, on: stack)
        return try runCompiled(function, code, with: [:], argumentsAt: base)
    }
}
