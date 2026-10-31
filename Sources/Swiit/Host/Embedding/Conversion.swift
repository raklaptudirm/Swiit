import Foundation

extension Interpreter {
    /// `value` as a `type`, converting as a call's argument is: nil if it is not one. A list's
    /// elements are converted too.
    public func converted(_ value: Value, to type: ScriptType) -> Value? {
        inCurrentTask { annotation(type).flatMap { conform(value, to: $0) } }
    }

    /// Text as a value of a Swift type, by the type's own rules: its initializer from text (`5` for
    /// an `Int`, a path for a `FilePath`) or the text literal it can be (`Character`). Nil if the
    /// type has neither, or the text is not one of its values. Which types have one shows in their
    /// initializers, but not which texts are valid: `Character("ab")` traps, and this gives nil.
    public func value(from text: String, as type: ScriptType) -> Value? {
        inCurrentTask {
            guard let annotation = annotation(type), let (bridged, _) = Bridge.type(of: annotation),
                let made = Bridge.value(of: bridged.name, from: text)
            else { return nil }
            return made
        }
    }

    /// The raw value an enum's declaration gives the case `value` is (`enum Level: Int { case low = 1 }`
    /// gives 1 for `Level.low`), if the enum has raw values. Nil for any other value. Its cases, labels
    /// and the rest of its declaration are `symbols(in:)` of its `typeID`.
    public func rawValue(of value: Value) -> Value? {
        inCurrentTask { value.enumCase?.rawValue }
    }

    /// A case without associated values of an enum a script or the host declared:
    /// `value(ofCase: "directory", in: "FileType")`. Nil if there is no such enum or case.
    public func value(forCase name: String, in enumType: Symbol.ID) -> Value? {
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
