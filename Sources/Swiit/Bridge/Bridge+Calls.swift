import Foundation
import SystemPackage

extension Interpreter {
    /// Runs a bridged member: binds its arguments as a call binds them, and
    /// its glue does the rest.
    func runBridged(_ typeName: String, _ index: Int, receiver: Expr?, _ arguments: [Argument]) throws -> Value {
        guard let member = Bridge.types[typeName]?.members[index] else { throw RuntimeError("no bridged member #\(index) of \(typeName)") }
        let function = Function(name: member.name, parameters: member.parameters, returnType: nil, body: member.body)
        var bindings = try bind(arguments, to: function).bindings
        if member.isMutating, let receiver, let result = try runMutatingInPlace(member, function, bindings, receiver) { return result }
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
    /// `xs.append(1)` on a variable holding a collection: the value is moved into a box the glue takes it from, so
    /// that it changes where it is. (Copied, it would cost the whole collection on every call.) Nil if this isn't
    /// that case, which then goes the long way round.
    func runMutatingInPlace(_ member: BridgedMember, _ function: Function, _ bindings: [String: Value], _ receiver: Expr) throws -> Value? {
        // A member that calls back into the program could see the variable while it is out.
        guard !member.parameters.contains(where: { $0.type.acceptsFunction }), let (root, path) = lvalue(receiver),
              scopeHolding(root)?.bindings[root].map({ $0.mutable }) == true,
              let place = try plainPlace(root, path, op: nil) else { return nil }
        // Only a collection (or a string) gains by it; anything else has no copy to save.
        let isCollection: Bool = try withPlace(root, place) { slot in
            switch slot {
            case .list, .dictionary, .string, .object(is SwiftValue): true
            default: false
            }
        }
        guard isCollection else { return nil }
        try checkAssignable(root, what: "use mutating method '\(member.name)' on")
        return try withPlace(root, place) { slot in
            let box = ReceiverBox(slot)
            slot = .nothing
            var arguments = bindings
            arguments["self"] = .object(box)
            defer { slot = box.value }
            guard case .list(let parts) = try invoke(function, with: arguments), parts.count == 2 else {
                throw RuntimeError("\(member.name) gave back no receiver")
            }
            return parts[0]
        }
    }

    /// A Swift property of a value, looked up when it runs, as a key path
    /// does; nil if its type has none of that name.
    func bridgedProperty(_ name: String, of value: Value) throws -> Value? {
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

    /// The Swift methods of a value named `name`, bound to it, looked up when it runs: what a call on a value whose type
    /// the checker did not know (a closure's `$0` in a pipeline stage) finds. Nil if its type has none.
    func bridgedMethods(_ name: String, of value: Value) -> Value? {
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
        guard let typeName else { return nil }
        let candidates = (Bridge.types[typeName]?.members ?? []).filter {
            $0.kind == .method && !$0.isStatic && !$0.isMutating && $0.name == name
        }.compactMap { member -> Function? in
            guard case .native(let call) = member.body else { return nil }
            let body = FunctionBody.native { interpreter, arguments in
                var arguments = arguments
                arguments["self"] = value
                return try call(interpreter, arguments)
            }
            return Function(name: member.name, parameters: member.parameters, returnType: nil, body: body)
        }
        return candidates.isEmpty ? nil : .function(OverloadSet(name: name, candidates: candidates))
    }
}
