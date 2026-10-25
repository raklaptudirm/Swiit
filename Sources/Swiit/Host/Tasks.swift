extension Interpreter {
    /// Makes `name` a global worked out each time it is read, of the type given: a host's `jobs`.
    public func register(
        computed name: String,
        type: ScriptType,
        _ read: @escaping @Sendable () -> Value
    ) {
        withMainTask {
            scopes[0].bindings[name] = Binding(computed: read)
            staticTypes[name] = TypeAnnotation(type)
        }
    }

    /// Starts a task: `body` runs script code on a thread of its own, as a Swift `Task` would, and
    /// the host keeps `state` for it (`taskState` while it runs). It ends with the scope that
    /// started it, unless joined first.
    public func startTask(
        state: AnyObject?,
        _ body: @escaping @Sendable () throws -> Value
    ) throws(Diagnostic) -> ScriptTask {
        do {
            return try inCurrentTask { try startTask(host: state, structured: true, body) }
        } catch {
            throw Diagnostic.of(error)
        }
    }

    /// Waits for a task to end, letting the other tasks run meanwhile, and gives what it gave or
    /// throws why it failed.
    public func join(_ task: ScriptTask) throws(Diagnostic) -> Value {
        do {
            return try inCurrentTask { try joinTask(task) }
        } catch {
            throw Diagnostic.of(error)
        }
    }

    /// Cancels the tasks the script has started and not joined, and waits for them, as the scope
    /// that started them closing would: how a host ends a script.
    public func cancelAndJoinTasks() {
        inCurrentTask { closeTasks(above: -1) }
    }
}
