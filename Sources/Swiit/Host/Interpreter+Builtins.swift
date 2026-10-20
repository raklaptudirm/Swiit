import Foundation

/// Builtins written in Swift. They're ordinary functions to the rest of
/// the host: the same help and overloads as Swiit ones.

extension Interpreter {
    /// Installs the builtins.
    func installBuiltinFunctions() {
        scopes[0].bindings["args"] = Binding(value: .list([]), mutable: false)
        let extensions = installPrelude()
        installPrint()
        installLanguageFunctions()
        // Swift's types by name, for their initializers and static members.
        for name in Bridge.types.keys {
            scopes[0].bindings[name] = Binding(value: .object(BridgedTypeName(name)), mutable: false)
        }
        do { try declarePreludeExtensions(extensions) } catch { preconditionFailure("the prelude: \(error)") }
    }
}
