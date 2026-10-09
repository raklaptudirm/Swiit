import Foundation
import SwishKit

/// Builtins written in Swift. They're ordinary functions to the rest of
/// the shell: the same flags, help, overloads and streaming as Swish ones.

extension Interpreter {
    /// Installs the builtins: the core's own, and the host's `libraries`
    /// (bridged functions and types, and declarations for the prelude).
    @_spi(Shell) public func installBuiltinFunctions(libraries added: [Library] = []) {
        libraries = [.standard] + added
        scopes[0].bindings["args"] = Binding(value: .list([]), mutable: false)
        installPrelude()
        installPrint()
        installStandardFunctions()
        // Swift's types by name, for their initializers and static members.
        for name in Bridge.types.keys {
            scopes[0].bindings[name] = Binding(value: .object(BridgedTypeName(name)), mutable: false)
        }
    }

    /// The shell's own functions, written in Swift (SwishStandardLibrary) and
    /// bridged: `pwd`, `readLine`. Each is an ordinary function to the rest
    /// of the shell, with its flags, help and overloads.
    private func installStandardFunctions() {
        for member in libraries.flatMap(\.functions) {
            let function = Function(
                name: member.name, parameters: member.parameters, returnType: member.returns, body: member.body,
                documentation: Documentation(summary: member.summary, parameters: member.parameterDocs),
                isThrowing: member.isThrowing, isRethrowing: member.isRethrowing, generics: member.generics
            )
            scopes[0].declare(function, named: member.name)
        }
    }

    /// Each builtin's body, by name, for the prelude's declarations: the
    /// core's own, then the installed libraries'. A sequence method's also
    /// says how it reads the sequence: each item (`filter`), or all of them
    /// (`sorted`).
    @_spi(Shell) public func builtinBodies() -> [String: (body: FunctionBody, input: Parameter?)] {
        var bodies: [String: (body: FunctionBody, input: Parameter?)] = [:]
        for library in libraries { bodies.merge(library.bodies) { _, new in new } }
        return bodies
    }
}
