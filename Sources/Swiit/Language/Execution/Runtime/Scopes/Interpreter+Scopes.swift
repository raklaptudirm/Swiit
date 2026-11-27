import Foundation

extension Interpreter {
    /// The innermost binding of `name`: in the scopes made since the frame began, the frame, then
    /// the scopes before it.
    func lookup(_ name: String) -> Binding? {
        let task = self.task
        // Read once: a copy of the array is cheaper than going through the task for each scope.
        let scopes = task.scopes
        var index = scopes.count - 1
        if let frame = task.frame {
            while index >= task.frameBase {
                if let found = scopes[index].binding(named: name) { return found }
                index -= 1
            }
            if let found = frame.binding(named: name) { return found }
        }
        while index >= 0 {
            if let found = scopes[index].binding(named: name) { return found }
            index -= 1
        }
        return nil
    }

    /// The innermost binding of `name` that is local: not a global or a builtin.
    func localBinding(_ name: String) -> Binding? {
        var index = scopes.count - 1
        if let frame = task.frame {
            while index >= max(task.frameBase, 2) {
                if let found = scopes[index].binding(named: name) { return found }
                index -= 1
            }
            if let found = frame.binding(named: name) { return found }
            index = min(index, task.frameBase - 1)
        }
        while index >= 2 {
            if let found = scopes[index].binding(named: name) { return found }
            index -= 1
        }
        return nil
    }

    /// What a closure or nested function keeps of the scopes it's made in:
    /// the global ones, and only the local variables its body names, each
    /// shared with where it's declared. Keeping whole scopes would keep the
    /// one the closure itself is stored in: a cycle, never freed.
    func captureScopes(_ names: NamesUsed) -> [Scope] {
        guard scopes.count > 2 || task.frame != nil else { return scopes }
        let local = scopes.dropFirst(2)
        let capture = Scope()
        for name in names.names {
            if let binding = localBinding(name) { capture.bindings[name] = binding }
        }
        // At the top level, with nothing local named, the globals are all it sees.
        if scopes.count == 2, capture.bindings.isEmpty { return scopes }
        // A local function declared further down is found where the closure was made; a body
        // given a frame has none (`FrameResolver`).
        capture.fallbacks = local.map { WeakScope(scope: $0) } + local.flatMap(\.fallbacks)
        return Array(scopes.prefix(2)) + [capture]
    }
}
