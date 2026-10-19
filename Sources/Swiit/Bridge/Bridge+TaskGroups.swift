import Foundation
import SwiitStandardLibrary

// Swift's task groups, bridged by hand like `Task`: each child is a task of
// the interpreter's, and the group gives their results in the order they end.

/// A task group's state: the children's results as they end, and how many are still going.
@_spi(Layer) public final class TaskGroupBox: @unchecked Sendable { // safe: every access holds its own lock
    nonisolated(unsafe) let shell: Interpreter // safe: an interpreter is touched only holding its lock
    let isThrowing: Bool
    private let condition = NSCondition()
    private var finished: [Result<Value, any Error>] = []
    private var pending = 0
    private var handles: [TaskHandle] = []
    var isCancelled = false

    init(_ shell: Interpreter, isThrowing: Bool) {
        self.shell = shell
        self.isThrowing = isThrowing
    }

    var isEmpty: Bool {
        condition.lock()
        defer { condition.unlock() }
        return pending == 0 && finished.isEmpty
    }

    /// Starts `operation` as a child of the task adding it.
    func add(_ operation: Value) throws {
        condition.lock()
        pending += 1
        condition.unlock()
        let shell = shell
        do {
            let handle = try shell.startTask(host: shell.newTaskHost?(), structured: false) { [self] in
                let result = Result { try shell.call(operation, with: []) }
                condition.lock()
                finished.append(result)
                condition.broadcast()
                condition.unlock()
                return .nothing
            }
            handles.append(handle)
        } catch {
            condition.lock()
            pending -= 1
            condition.unlock()
            throw error
        }
        if isCancelled { handles.last?.cancel() }
    }

    /// The next child's result, in the order they end; nil when none is left.
    func next() throws -> Value? {
        let cancellation = shell.task.cancellation
        let outcome: Result<Value, any Error>? = shell.suspend(wake: { [self] in
            condition.lock()
            condition.broadcast()
            condition.unlock()
        }) { [self] in
            condition.lock()
            defer { condition.unlock() }
            while finished.isEmpty && pending > 0 && !cancellation.isSet { condition.wait() }
            guard !finished.isEmpty else { return nil }
            pending -= 1
            return finished.removeFirst()
        }
        guard let outcome else {
            if cancellation.isSet { throw Cancelled() }
            return nil
        }
        let value = try outcome.get()
        return value == .nothing ? Value.nothing : value
    }

    func cancelAll() {
        isCancelled = true
        handles.forEach { $0.cancel() }
    }

    /// Waits for every child, giving the first error one threw.
    func waitForAll() throws {
        var failure: (any Error)?
        while true {
            do {
                guard try next() != nil || !isEmpty else { break }
            } catch {
                failure = failure ?? error
                if error is Cancelled { break }
            }
        }
        if let failure { throw failure }
    }
}

extension Bridge {
    private static func group(_ value: Value?) throws -> TaskGroupBox {
        try SwiftValue.unbox(TaskGroupBox.self, value ?? .nothing)
    }

    private static func groupType(_ name: String, isThrowing: Bool) -> BridgedType {
        let element = TypeAnnotation.parameter("ChildTaskResult")
        return BridgedType(
            name: name, genericParameters: ["ChildTaskResult"], conformances: [:],
            associatedTypes: ["Element": element],
            members: [
                member(.method, "addTask", parameters: [Parameter(label: "operation", name: "operation",
                           type: .functionType([], element, throws: isThrowing, async: .async))], returns: .void,
                       summary: "Starts the operation as a child task of the group.") { _, arguments in
                    try group(arguments["self"]).add(arguments["operation"]!)
                    return .nothing
                },
                member(.method, "next", returns: .optional(element), throwing: isThrowing, effect: .async,
                       summary: "The result of the next child to end, or nil when none is left.") { _, arguments in
                    try group(arguments["self"]).next() ?? .nothing
                },
                member(.method, "waitForAll", returns: .void, throwing: isThrowing, effect: .async,
                       summary: "Waits for every child.") { _, arguments in
                    try group(arguments["self"]).waitForAll()
                    return .nothing
                },
                member(.method, "cancelAll", returns: .void, summary: "Asks every child to stop.") { _, arguments in
                    try group(arguments["self"]).cancelAll()
                    return .nothing
                },
                member(.property, "isEmpty", returns: .bool, summary: "Whether no child is left.") { _, arguments in
                    .bool(try group(arguments["self"]).isEmpty)
                },
                member(.property, "isCancelled", returns: .bool, summary: "Whether the group was asked to stop.") { _, arguments in
                    .bool(try group(arguments["self"]).isCancelled)
                },
            ]
        )
    }

    nonisolated(unsafe) static let taskGroupTypes: [BridgedType] = [ // safe: set once, before anything reads it
        groupType("TaskGroup", isThrowing: false), groupType("ThrowingTaskGroup", isThrowing: true),
    ]

    /// `withTaskGroup(of: Int.self) { group in … }`: the body runs with a group, and the group's
    /// children are waited for when it ends (or cancelled, if it threw).
    static func taskGroupFunction(_ name: String, isThrowing: Bool) -> Function {
        let typeName = isThrowing ? "ThrowingTaskGroup" : "TaskGroup"
        return Function(
            name: name,
            parameters: [
                Parameter(label: "of", name: "childType", type: .any),
                Parameter(label: nil, name: "body", type: .functionType([.generic(typeName, [.unknown])], .parameter("Result"), throws: isThrowing, async: .async)),
            ],
            returnType: .parameter("Result"),
            body: .native { shell, arguments in
                let box = TaskGroupBox(shell, isThrowing: isThrowing)
                let value = SwiftValue.make(box, as: typeName)
                do {
                    let result = try shell.call(arguments["body"]!, with: [value])
                    try box.waitForAll()
                    return result
                } catch {
                    box.cancelAll()
                    try? box.waitForAll()
                    throw error
                }
            },
            documentation: Documentation(summary: "Runs the body with a group of child tasks, waiting for them when it ends.", parameters: [:]),
            isThrowing: isThrowing, effect: .async, generics: ["Result": []]
        )
    }
}
