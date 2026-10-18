
// What a host can ask of the functions a script can call: to list the commands it registered, say, or to show
// their parameters in a help screen. The interpreter's own types stay private to it; these describe a function the
// way its signature reads.

/// A parameter of a function a script can call.
public struct ParameterInfo: Sendable, Hashable {
    /// The argument label; nil when the argument is written without one.
    public let label: String?
    /// The name the function's body uses.
    public let name: String
    public let type: TypeAnnotation
    public let isVariadic: Bool
    /// Whether a call may leave it out.
    public let hasDefault: Bool
}

/// One function a script can call, or one overload of it.
public struct FunctionInfo: Sendable, Hashable {
    public let name: String
    public let parameters: [ParameterInfo]
    /// What it gives back; nil when it gives nothing.
    public let returns: TypeAnnotation?
    public let isThrowing: Bool
    public let isAsync: Bool
}

extension Interpreter {
    /// The functions registered with `register`, and those scripts have declared, with each overload of a name.
    /// The interpreter's own (`print`, `map`) are not among them; `functions(named:)` finds those too.
    public var functions: [FunctionInfo] {
        scopes[1].bindings.flatMap { entry in functionInfo(entry.value.value) }
    }

    /// Each overload of the function `name` is bound to, or none if it names something else.
    public func functions(named name: String) -> [FunctionInfo] {
        lookup(name).map { functionInfo($0.value) } ?? []
    }

    private func functionInfo(_ value: Value) -> [FunctionInfo] {
        guard case .function(let callable) = value else { return [] }
        let candidates = (callable as? OverloadSet)?.candidates ?? (callable as? Function).map { [$0] } ?? []
        return candidates.map { function in
            FunctionInfo(
                name: function.name ?? "closure",
                parameters: function.parameters.map {
                    ParameterInfo(label: $0.label, name: $0.name, type: $0.type, isVariadic: $0.variadic, hasDefault: $0.defaultValue != nil)
                },
                returns: function.returnType.flatMap { $0 == .void ? nil : $0 },
                isThrowing: function.isThrowing,
                isAsync: function.effect != .sync)
        }
    }
}

extension Interpreter {
    // MARK: Host types

    /// Describes the objects whose `typeName` is `name`, for the checker: the protocol they are used as.
    /// `describeHostType("Node", as: "var label: String { get }; func rename(to: String) throws")` lets a script use a
    /// `Node` with its members checked before it runs, and pass one where a `Node` is asked for. The description is
    /// the host's promise; `missingMembers(of:)` checks an object against it.
    public func describeHostType(_ name: String, as members: String) throws {
        _ = try eval("protocol \(name) { \(members) }")
    }

    /// What the description of `object`'s type asks that the object doesn't have (the names of its members), or
    /// nothing if it has them all or its type hasn't been described.
    public func missingMembers(of object: any SwiitObject) -> [String] {
        guard let description = protocolType(named: object.typeName)?.declaration else { return [] }
        let required = description.properties.map(\.name) + description.methods.map(\.name)
        let present = Set(object.memberNames)
        return required.filter { !present.contains($0) }
    }
}
