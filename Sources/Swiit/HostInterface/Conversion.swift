import Foundation

extension Interpreter {
    /// `value` as a `type`, converting as a call's argument is: nil if it is not one. A list's
    /// elements are converted too.
    public func converted(_ value: Value, to type: ScriptType) -> Value? {
        inCurrentTask { annotation(type).flatMap { conform(value, to: $0) } }
    }

    func value(forCase name: String, in enumType: Symbol.ID) -> Value? {
        inCurrentTask {
            guard let type = self.enumType(named: enumType.name),
                let definition = type.case(named: name),
                definition.labels.isEmpty
            else { return nil }
            return .enumValue(Value.EnumCase(type: type, name: name))
        }
    }

    /// A value as a script's interpolation shows it, honoring the `description` a script's own type
    /// declares; `debug` for the form `print` of a collection shows, with strings quoted.
    public func description(of value: Value, debug: Bool = false) throws(Diagnostic) -> String {
        do {
            return try inCurrentTask { try describing(value, debug: debug) }
        } catch {
            throw Diagnostic.of(error)
        }
    }

    /// The type a value has in a script.
    public func scriptType(of value: Value) -> ScriptType {
        inCurrentTask { scriptType(TypeChecker(interpreter: self).type(of: value)) }
    }
}

extension Symbol.ID {
    /// A case without associated values of the enum the ID names, a script's or the host's:
    /// `id.enumCase(named: "directory", in: interpreter)`. Nil if the ID names no enum, or the enum
    /// has no such case.
    public func enumCase(named name: String, in interpreter: Interpreter) -> Value? {
        interpreter.value(forCase: name, in: self)
    }
}
