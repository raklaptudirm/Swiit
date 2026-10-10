import Foundation
import SwishKit

/// The builtins' types and signatures, written in Swish and read when the
/// shell starts. The checker works from these; the bodies are in Swift
/// (StructuredBuiltins.swift), found by name. Doc comments are what `help`
/// and `--help` show.
extension Interpreter {
    static let prelude = #"""
    /// What `catch` binds: any error, which tells what went wrong. Cast it to
    /// get at more, as in Swift: `if let failure = error as? CommandFailure`.
    struct Error {
        let localizedDescription: String
    }

    """#

    /// Reads the prelude, binding its types, functions and sequence
    /// methods in the outermost scope with their Swift bodies.
    @_spi(Shell) public func installPrelude() {
        // The Swift types the declarations may name.
        let bridgedTypeNames = Dictionary(uniqueKeysWithValues: Bridge.types.keys.map { ($0, NameKind.type) })
        let program: Program
        do {
            program = try Parser.parsePrelude(([Interpreter.prelude] + libraries.flatMap { [$0.types, $0.declarations] }).joined(separator: "\n"), bound: bridgedTypeNames)
        } catch {
            preconditionFailure("the prelude doesn't parse: \(error)")
        }
        let natives = builtinBodies()
        for statement in program.statements {
            switch statement {
            case .structDecl(let decl):
                // Declared as any struct is, then moved out to the builtins.
                do { try declare(decl, natives: natives.mapValues(\.body)) } catch { preconditionFailure("the prelude's \(decl.name): \(error)") }
                scopes[0].bindings[decl.name] = scopes[scopes.count - 1].bindings.removeValue(forKey: decl.name)
            case .enumDecl(let decl):
                do { try declare(decl) } catch { preconditionFailure("the prelude's \(decl.name): \(error)") }
                scopes[0].bindings[decl.name] = scopes[scopes.count - 1].bindings.removeValue(forKey: decl.name)
            case .function(let decl):
                guard let native = natives[decl.name] else { preconditionFailure("no body for \(decl.name)") }
                let function = builtinFunction(decl, native.body, input: nil)
                scopes[0].declare(function, named: decl.name)
            case .extensionDecl(_, let methods):
                for method in methods {
                    guard let native = natives["Sequence." + method.name] else {
                        preconditionFailure("no body for Sequence.\(method.name)")
                    }
                    let function = builtinFunction(method, native.body, input: native.input)
                    let existing = sequenceMethods[method.name]?.candidates ?? []
                    sequenceMethods[method.name] = OverloadSet(name: method.name, candidates: existing + [function])
                }
            default:
                preconditionFailure("the prelude only declares")
            }
        }
    }

    /// A builtin as the shell's functions are: the prelude's signature, a
    /// Swift body, and for a sequence method, the `@input` it reads the
    /// sequence from (each item, or all of them).
    private func builtinFunction(_ decl: FunctionDecl, _ body: FunctionBody, input: Parameter?) -> Function {
        Function(
            name: decl.name, parameters: (input.map { [$0] } ?? []) + decl.parameters, returnType: decl.returnType,
            body: body, documentation: decl.documentation, isThrowing: decl.isThrowing,
            isRethrowing: decl.isRethrowing, generics: decl.generics
        )
    }
}
