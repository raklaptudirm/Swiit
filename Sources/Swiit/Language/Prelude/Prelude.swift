import Foundation

/// The builtins' types and signatures, written in Swiit and read when the
/// host starts. The checker works from these; the bodies are in Swift
/// (StructuredBuiltins.swift), found by name. Doc comments are what `help`
/// and `--help` show.
extension Interpreter {
    static let prelude = #"""
    /// What `catch` binds: any error, which tells what went wrong. Cast it to
    /// get at more, as in Swift: `if let failure = error as? CommandFailure`.
    struct Error {
        let localizedDescription: String
    }

    /// What has no values: a `Task<Int, Never>` can't fail.
    enum Never {}

    /// A value, or the error that kept it from being made.
    enum Result<Success, Failure: Error> {
        case success(Success)
        case failure(Failure)

        init(catching body: () throws -> Success) {
            do { self = Result.success(try body()) } catch { self = Result.failure(error) }
        }

        /// The value, or throws the error.
        func get() throws -> Success {
            switch self {
            case .success(let value): return value
            case .failure(let error): throw error
            }
        }

        func map<NewSuccess>(_ transform: (Success) -> NewSuccess) -> Result<NewSuccess, Failure> {
            switch self {
            case .success(let value): return .success(transform(value))
            case .failure(let error): return .failure(error)
            }
        }

        func mapError<NewFailure: Error>(_ transform: (Failure) -> NewFailure) -> Result<Success, NewFailure> {
            switch self {
            case .success(let value): return .success(value)
            case .failure(let error): return .failure(transform(error))
            }
        }

        func flatMap<NewSuccess>(_ transform: (Success) -> Result<NewSuccess, Failure>) -> Result<NewSuccess, Failure> {
            switch self {
            case .success(let value): return transform(value)
            case .failure(let error): return .failure(error)
            }
        }
    }

    /// What `Mirror(reflecting:)` shows of a value: its stored properties, in order.
    struct Mirror {
        let children: [(label: String?, value: Any)]

        init(reflecting subject: Any) {
            children = __mirrorChildren(subject)
        }
    }

    /// The type of no value, for `Void.self` where a type is passed.
    enum Void {}

    /// What a task that was asked to stop throws, from `Task.checkCancellation()`
    /// or `Task.sleep`.
    struct CancellationError: Error {
        let localizedDescription: String
    }

    """#

    /// The prelude as source: the language's own, then each library's types and declarations.
    var preludeSource: String {
        ([Interpreter.prelude] + libraries.flatMap { [$0.types, $0.declarations] }).joined(separator: "\n")
    }

    /// Reads the prelude, binding its types, functions and sequence
    /// methods in the outermost scope with their Swift bodies.
    @discardableResult
    func installPrelude() -> [ExtensionDecl] {
        // The Swift types the declarations may name.
        let bridgedTypeNames = Dictionary(uniqueKeysWithValues: Bridge.types.keys.map { ($0, NameKind.type) })
        let program: Program
        do {
            program = try PreludeCache.program(for: preludeSource, bound: bridgedTypeNames)
        } catch {
            preconditionFailure("the prelude doesn't parse: \(error)")
        }
        do { return try declarePrelude(program, natives: builtinBodies()) } catch { preconditionFailure("the prelude: \(error)") }
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
                guard let native = natives[decl.name] else { throw RuntimeError("no body for \(decl.name)") }
                let function = builtinFunction(decl, native.body, input: nil)
                scopes[0].declare(function, named: decl.name)
            case .extensionDecl(_, let methods):
                for method in methods {
                    guard let native = natives["Sequence." + method.name] else {
                        throw RuntimeError("no body for Sequence.\(method.name)")
                    }
                    let function = builtinFunction(method, native.body, input: native.input)
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
