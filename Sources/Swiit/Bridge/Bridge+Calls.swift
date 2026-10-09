import Foundation
import SwishKit
import SystemPackage

extension Interpreter {
    /// Runs a bridged member: binds its arguments as a call binds them, and
    /// its glue does the rest.
    @_spi(Shell) public func runBridged(_ typeName: String, _ index: Int, receiver: Expr?, _ arguments: [Argument]) throws -> Value {
        guard let member = Bridge.types[typeName]?.members[index] else { throw RuntimeError("no bridged member #\(index) of \(typeName)") }
        let function = Function(name: member.name, parameters: member.parameters, returnType: nil, body: member.body)
        var bindings = try bind(arguments, to: function).bindings
        if let receiver {
            let value = try evaluate(receiver)
            // Through `?.`: nil stays nil. (Optional's own members take nil.)
            if value == .nothing && typeName != "Optional" { return .nothing }
            bindings["self"] = value
        }
        guard member.isMutating, let receiver else { return try invoke(function, with: bindings) }
        // `xs.append(1)`: Swift changes a copy, which goes back into `xs`.
        guard case .list(let parts) = try invoke(function, with: bindings), parts.count == 2 else {
            throw RuntimeError("\(typeName).\(member.name) gave back no receiver")
        }
        try mutate(receiver, by: member.name) { _ in parts[1] }
        return parts[0]
    }
}

extension Interpreter {
    /// A Swift property of a value, looked up when it runs, as a key path
    /// does; nil if its type has none of that name.
    @_spi(Shell) public func bridgedProperty(_ name: String, of value: Value) throws -> Value? {
        let typeName: String? = switch value {
        case .string: "String"
        case .int: "Int"
        case .double: "Double"
        case .bool: "Bool"
        case .list: "Array"
        case .dictionary: "Dictionary"
        case .object(let box as SwiftValue): box.typeName
        default: nil
        }
        guard let typeName, let member = Bridge.types[typeName]?.members.first(where: {
            $0.kind == .property && !$0.isStatic && $0.name == name
        }) else { return nil }
        let function = Function(name: member.name, parameters: [], returnType: nil, body: member.body)
        return try invoke(function, with: ["self": value])
    }
}
