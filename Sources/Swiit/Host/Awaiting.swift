
/// What `await` waits for, which a host registers: the type of the operand (a handle the host made), the type it gives, and
/// how to wait. Without one, `await` is refused.
public struct Awaiting {
    public var operand: ValueType
    public var result: ValueType
    /// Waits for the handle, or with no operand for the latest one; `throwing` for `try await`.
    var perform: (_ handle: Value?, _ throwing: Bool) throws -> Value
    /// Whether a value is one of its handles; `await` of anything else is an `async` call's, and gives the value.
    var isHandle: (Value) -> Bool
    /// What awaiting a handle of this type gives, where it depends on what the handle holds (a shell's `Job<Int>` gives an
    /// Int); `result` else.
    var resultOf: (ValueType) -> ValueType?

    public init(operand: ValueType, result: ValueType, isHandle: @escaping (Value) -> Bool = { _ in true },
                resultOf: @escaping (ValueType) -> ValueType? = { _ in nil },
                perform: @escaping (Value?, Bool) throws -> Value) {
        self.operand = operand
        self.result = result
        self.isHandle = isHandle
        self.resultOf = resultOf
        self.perform = perform
    }
}

extension Interpreter {
    /// Makes `await` wait for the host's own handles. A failure to wait is a `ScriptError`.
    public func register(_ awaiting: Awaiting) {
        withMainTask { self.awaiting = awaiting }
    }

    /// Makes `name` a global worked out each time it is read, of the type given: a shell's `jobs`.
    public func register(computed name: String, type: ValueType, _ read: @escaping @Sendable () -> Value) {
        withMainTask {
            scopes[0].bindings[name] = Binding(computed: read)
            staticTypes[name] = TypeAnnotation(type)
        }
    }

    /// Starts a task: `body` runs script code on a thread of its own, as a Swift `Task` would, and the host keeps `state` for it
    /// (`taskState` while it runs). It ends with the scope that started it, unless joined first.
    public func startTask(state: AnyObject?, _ body: @escaping @Sendable () throws -> Value) throws(Diagnostic) -> TaskHandle {
        do {
            return try inCurrentTask { try startTask(host: state, structured: true, body) }
        } catch {
            throw Diagnostic.of(error)
        }
    }

    /// Waits for a task to end, letting the other tasks run meanwhile, and gives what it gave or throws why it failed.
    public func join(_ task: TaskHandle) throws(Diagnostic) -> Value {
        do {
            return try inCurrentTask { try joinTask(task) }
        } catch {
            throw Diagnostic.of(error)
        }
    }

    /// Cancels the tasks the script has started and not joined, and waits for them, as the scope that started them closing
    /// would: how a shell ends a script.
    public func finishTasks() {
        inCurrentTask { closeTasks(above: -1) }
    }
}
