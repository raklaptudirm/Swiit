import Foundation
import SwiftSyntax
import Synchronization

// Registering Swift closures and symbols for scripts to call.

extension Interpreter {
    /// Makes a described function one scripts can call, checked like any they declare. A member of a
    /// type is registered with its type (`HostType.Builder`), so this takes only a function.
    public func register(_ function: ImplementedSymbol) {
        guard function.function != nil else {
            preconditionFailure("\(function.name) is a member of a type: register it with its type")
        }
        withMainTask {
            for type in function.enums {
                scopes[1].bindings[type.name] = Binding(value: .object(type), mutable: false)
            }
            scopes[1].declare(Self.hostFunction(function), named: function.name)
        }
    }

    /// Makes a Swift closure a function scripts can call: `ImplementedSymbol.function(_:labels:throwing:_:)`
    /// registered. A closure that gives a `Value` gives scripts an `Any`; one that gives a type
    /// a script declared is registered as `ImplementedSymbol.function(name:returns:body:)`, with
    /// `.named(id)` of that type for `returns`.
    public func register<each Argument: BridgedType, Result: BridgedType>(
        _ name: String,
        labels: [String?] = [],
        throwing: Bool = false,
        _ body: @escaping @Sendable (repeat each Argument) throws -> Result
    ) {
        register(ImplementedSymbol.function(name, labels: labels, throwing: throwing, body))
    }

    /// As above, for a closure that returns nothing.
    public func register<each Argument: BridgedType>(
        _ name: String,
        labels: [String?] = [],
        throwing: Bool = false,
        _ body: @escaping @Sendable (repeat each Argument) throws -> Void
    ) {
        register(ImplementedSymbol.function(name, labels: labels, throwing: throwing, body))
    }
}
