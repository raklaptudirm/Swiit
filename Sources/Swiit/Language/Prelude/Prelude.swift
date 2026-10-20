import Foundation

/// The builtins' types and signatures are Resources/Prelude.swift, embedded in the target by Package.swift.
extension Interpreter {
    static let prelude = String(decoding: PackageResources.Prelude_swift, as: UTF8.self)

    /// Reads the prelude, binding its types, functions and sequence
    /// methods in the outermost scope with their Swift bodies.
    @discardableResult
    func installPrelude() -> [ExtensionDecl] {
        // The Swift types the declarations may name.
        let bridgedTypeNames = Dictionary(uniqueKeysWithValues: Bridge.types.keys.map { ($0, NameKind.type) })
        let program: Program
        do {
            program = try PreludeCache.program(for: Interpreter.prelude, bound: bridgedTypeNames)
        } catch {
            preconditionFailure("the prelude doesn't parse: \(error)")
        }
        do { return try declarePrelude(program, natives: [:]) } catch { preconditionFailure("the prelude: \(error)") }
    }

    /// Declares a prelude's statements with the Swift bodies found by name; the additions to types are returned, to be
    /// declared once the rest is.
    func declarePrelude(_ program: Program, natives: [String: (body: FunctionBody, input: Parameter?)]) throws -> [ExtensionDecl] {
        var extensions: [ExtensionDecl] = []
        for statement in program.statements {
            switch statement {
            case .structDecl(let decl):
                // Declared as any struct is, then moved out to the builtins.
                try declare(decl, natives: natives.mapValues(\.body))
                scopes[0].bindings[decl.name] = scopes[scopes.count - 1].bindings.removeValue(forKey: decl.name)
            case .enumDecl(let decl):
                try declare(decl)
                scopes[0].bindings[decl.name] = scopes[scopes.count - 1].bindings.removeValue(forKey: decl.name)
            case .typeExtension(let decl):
                // A host's addition to a type, with its body in Swiit (`extension Int { var mb: FileSize { … } }`): declared once the
                // Swift types are bound by name, so that its body can be checked as a program's is.
                extensions.append(decl)
            case .protocolDecl(let decl):
                try declare(decl)
                scopes[0].bindings[decl.name] = scopes[scopes.count - 1].bindings.removeValue(forKey: decl.name)
            case .function(let decl):
                // Written with a body, it is Swiit's; without, Swift's by name.
                let function: Function
                if let native = natives[decl.name] {
                    function = builtinFunction(decl, native.body, input: nil)
                } else if !decl.body.statements.isEmpty {
                    function = builtinFunction(decl, .swiit(decl.body), input: nil)
                } else {
                    throw RuntimeError("no body for \(decl.name)")
                }
                scopes[0].declare(function, named: decl.name)
            case .extensionDecl(_, let methods):
                for method in methods {
                    let function: Function
                    if let native = natives["Sequence." + method.name] {
                        function = builtinFunction(method, native.body, input: native.input)
                    } else if !method.body.statements.isEmpty {
                        // The sequence, as a list, is `self`; the body is checked as a function's is, so that what it calls is resolved.
                        let receiver = Parameter(label: nil, name: "self", type: .list(.parameter("Element")))
                        var written = method
                        written.parameters = [receiver] + method.parameters
                        written.generics["Element", default: []] += []
                        let checked = try checkedSequenceMethod(written)
                        guard case .function(let resolved)? = checked.statements.first else { throw RuntimeError("Sequence.\(method.name)") }
                        var shaped = resolved
                        shaped.parameters.removeFirst()
                        function = builtinFunction(shaped, .swiit(resolved.body), input: receiver)
                    } else {
                        throw RuntimeError("no body for Sequence.\(method.name)")
                    }
                    let existing = sequenceMethods[method.name]?.candidates ?? []
                    sequenceMethods[method.name] = OverloadSet(name: method.name, candidates: existing + [function])
                }
            default:
                throw RuntimeError("a prelude only declares")
            }
        }
        return extensions
    }

    /// Declares what a host adds to the language itself: types, protocols, functions and what every sequence has, written as
    /// Swift declarations whose bodies are in Swift too. A function or method written without a body (`func next() -> Int`)
    /// takes the body registered under its name (`"hello"`), or `Type.method` for a method (`"Counter.next"`, `"Sequence.firsts"`).
    /// What is declared is the host's: it is a builtin to `help`, and a script's own declarations may overload it.
    public func prelude(
        _ source: String, bodies: [String: @Sendable (_ arguments: [String: Value]) throws -> Value] = [:]
    ) throws(Diagnostic) {
        do {
            try withMainTask {
                // The names it may use are those declared already, and Swift's own types.
                let names = globalNames()
                let program = try PreludeCache.program(for: source, bound: names, keyed: true)
                // A method every sequence has gets the sequence, as a list, in `self`.
                let natives = Dictionary(uniqueKeysWithValues: bodies.map { name, call in
                    (name, (body: FunctionBody.native { interpreter, arguments in
                        do { return try call(arguments) } catch { throw interpreter.hostFailure(error, in: name) }
                    }, input: name.hasPrefix("Sequence.")
                        ? Parameter(label: nil, name: "self", type: .list(.parameter("Element"))) : nil))
                })
                try declarePreludeExtensions(try declarePrelude(program, natives: natives))
            }
        } catch let error as SyntaxError {
            throw Diagnostic(kind: .syntax, message: error.description, range: error.range)
        } catch {
            throw Diagnostic.of(error)
        }
    }

    /// A sequence method written in Swiit, with what its body calls resolved.
    private func checkedSequenceMethod(_ method: FunctionDecl) throws -> Program {
        do {
            return try TypeChecker(interpreter: self).check(Program(statements: [.function(method)]))
        } catch {
            throw RuntimeError("Sequence.\(method.name): \(error)")
        }
    }

    /// A builtin as the host's functions are: the prelude's signature, a
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

/// The prelude's tree, by its source: reading it costs more than an
/// interpreter that starts often should pay, and the tree is a value, so
/// interpreters with the same libraries share one reading.
private enum PreludeCache {
    nonisolated(unsafe) private static var programs: [String: Program] = [:] // safe: guarded by `lock`
    private static let lock = NSLock()

    /// `keyed`: what the names bound are is part of what is read, so part of the key.
    static func program(for source: String, bound: [String: NameKind], keyed: Bool = false) throws(SyntaxError) -> Program {
        // The names a type may be spelled with come from the bridge, which doesn't change.
        let key = keyed ? source + "\u{0}" + bound.keys.sorted().joined(separator: ",") : source
        lock.lock()
        if let known = programs[key] { lock.unlock(); return known }
        lock.unlock()
        let program = try SwiftSyntaxFrontEnd().parsePrelude(source, bound: bound)
        lock.lock()
        programs[key] = program
        lock.unlock()
        return program
    }
}

extension Interpreter {
    /// The prelude's additions to types, with their bodies checked so that what they call is resolved before they run.
    func declarePreludeExtensions(_ extensions: [ExtensionDecl]) throws {
        for decl in extensions {
            do {
                let checked = try TypeChecker(interpreter: self).check(Program(statements: [.typeExtension(decl)]))
                for case .typeExtension(let resolved) in checked.statements { try declare(resolved) }
            } catch let error as TypeError {
                throw RuntimeError("the extension of \(decl.typeName): \(error.message)")
            }
        }
    }
}
