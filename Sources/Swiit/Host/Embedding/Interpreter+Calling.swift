import Foundation
import SwiftSyntax
import Synchronization

// Reading a script's globals and members, making its values and calling its functions.

extension Interpreter {
    /// A global of the script: what `name` is bound to, if anything. Setting one makes it a
    /// constant for scripts to read.
    public subscript(name: String) -> Value? {
        get { withMainTask { lookup(name)?.value } }
        set {
            withMainTask {
                guard let newValue else {
                    scopes[1].bindings[name] = nil
                    return
                }
                scopes[1].bindings[name] = Binding(value: newValue, mutable: false)
            }
        }
    }

    /// A member of a value as a script reads it: `value(of: "columns", in: type)` is
    /// `Type.columns`.
    public func value(forMember member: String, of value: Value) throws(Diagnostic) -> Value {
        do {
            return try withMainTask { try self.member(member, of: value) }
        } catch {
            throw Diagnostic.of(error)
        }
    }

    /// A value of a type, made by calling its initializer with `arguments`, as `call` does by the
    /// type's name but by its ID: how a host builds a struct or a class of the program's own, with
    /// the declaration's ID, its defaults and its checks, or a Swift type (`Int`, a registered
    /// `FileSize`) from its initializers. It throws for an ID that names no such type: another
    /// interpreter's, one declared again since, or a Swift type that is not registered.
    public func make(
        _ type: Symbol.ID,
        arguments: [(label: String?, value: Value)] = []
    ) throws(Diagnostic) -> Value {
        let current = inCurrentTask {
            switch type.kind {
            case .declared: isCurrent(type)
            case .host: bridgedInitializers(of: type.name) != nil
            case .parameter: false
            }
        }
        guard current else {
            throw Diagnostic(
                kind: .type,
                message: "\(type.name) is not a type this program or the host provides"
            )
        }
        return try call(type.name, arguments: arguments)
    }

    /// Calls a function by name, or a method of `receiver`, as a script's call with these arguments
    /// would: the overload is chosen by the labels and the values given, and what is left out takes
    /// its default. Without a receiver the name may be a type's, which calls its initializers, as
    /// `Point(x: 1)` and `Int("5")` do. From a host function it runs in the calling script's task;
    /// from outside, as the main one, and it is a run of its own: its steps, output and time are
    /// counted from the call, and a stop asked for before it does not end it.
    @discardableResult
    public func call(
        _ name: String,
        on receiver: Value? = nil,
        arguments: [(label: String?, value: Value)] = []
    ) throws(Diagnostic) -> Value {
        let written = arguments.map { Argument(label: $0.label, value: .literal($0.value)) }
        // Outside a run, the call is one: it starts with the steps, the time and the stop of a
        // run of its own.
        let isRun = !lock.isHeldByCurrentThread
        do {
            return try inCurrentTask { () throws -> Value in
                if isRun { self.beginRun() }
                // A Swift type's method by that name, when arguments are given: `count { … }` is a
                // method, not the property `count`. Where the prelude has a sequence method of the
                // name too, Swift's wins if it takes these arguments, as it does when a script is
                // checked.
                if let receiver, let methods = bridgedMethods(name, of: receiver),
                    !arguments.isEmpty || sequenceMethods[name] != nil
                {
                    var fits = true
                    if sequenceMethods[name] != nil,
                        case .function(let set as OverloadSet) = methods.storage
                    {
                        fits = set.candidates.contains { (try? self.bind(written, to: $0)) != nil }
                    }
                    if fits { return try self.evaluate(.call(.literal(methods), written)) }
                }
                let callee: Expr = receiver.map { .member(.literal($0), name) } ?? .variable(name)
                return try self.evaluate(.call(callee, written))
            }
        } catch {
            throw Diagnostic.of(error)
        }
    }

    /// Runs `body` as the task that is running now, or as the main one when no script is.
    func inCurrentTask<T>(_ body: () throws -> T) rethrows -> T {
        lock.isHeldByCurrentThread ? try body() : try withMainTask(body)
    }
}
