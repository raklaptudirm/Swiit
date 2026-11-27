import Foundation

// Closures made by compiled code, and the cells of the variables they capture.

// safe: a cell is read and changed only holding the interpreter lock, as every variable is
/// A variable a closure captures is held in the register of the frame that declared it as the cell
/// itself, which the closure's scope has a binding of too, so the two see each other's changes. So is the
/// cell of `self` in a method.
extension Binding.Cell: LanguageObject, @unchecked Sendable {
    var typeName: String { "Variable" }

    var memberNames: [String] { [] }

    func member(_ name: String) -> Value? { nil }

    var description: String { value.description }

    var debugDescription: String { value.debugDescription }
}

extension Interpreter {
    /// The cell a captured local is kept in.
    func cell(_ value: Value) throws -> Binding.Cell {
        guard case .object(let object) = value.storage, let cell = object as? Binding.Cell else {
            throw RuntimeError("a captured variable lost its cell")
        }
        return cell
    }

    /// A closure, as the tree evaluator makes one: it keeps the global scopes, the cells of the
    /// locals it names, and the values its capture list takes, each weakly if it says so. A nested
    /// function is made the same way, with the name and the facts its declaration gives it.
    func makeClosure(
        _ site: ClosureSite,
        _ registers: UnsafeMutablePointer<Value>
    ) throws -> Function {
        let capture = Scope()
        for local in site.cells {
            let held = registers[Int(local.register)]
            guard case .object(let object) = held.storage, let cell = object as? Binding.Cell else {
                // A function declared in a block is made as the block begins, too, before the
                // locals declared after it, which it cannot name.
                if case .declaration = site.source, held == .nothing { continue }
                throw RuntimeError("a captured variable lost its cell")
            }
            capture.bindings[local.name] = Binding(cell: cell, mutable: local.mutable)
        }
        for name in site.others {
            if let binding = localBinding(name) { capture.bindings[name] = binding }
        }
        let scopes = task.scopes
        // A name the closure's code names without writing it (`self`, which the checker puts before a
        // member) is found where the closure was made, as the tree evaluator's closures find it.
        let local = scopes.dropFirst(2)
        capture.fallbacks = local.map { WeakScope(scope: $0) } + local.flatMap(\.fallbacks)
        var captured =
            scopes.count == 2 && capture.bindings.isEmpty
            ? scopes : Array(scopes.prefix(2)) + [capture]
        if !site.captures.isEmpty {
            let taken = Scope()
            for item in site.captures {
                var value = registers[Int(item.register)]
                if item.isWeak || item.isUnowned,
                    case .object(let instance as ClassInstance) = value.storage
                {
                    value = .object(WeakReference(instance))
                }
                taken.bindings[item.name] = Binding(value: value, mutable: false)
            }
            captured.append(taken)
        }
        let made: Function
        switch site.source {
        case .literal(let literal):
            made = Function(
                name: nil,
                parameters: literal.parameters,
                returnType: literal.returnType,
                body: .swiit(literal.body),
                captured: captured
            )
        case .declaration(let decl):
            made = Function(declared: decl, captured: captured)
        }
        // Each is a new function; the code of the first serves the others the same scopes hold.
        switch site.code {
        case .code(let shared) where shared.capturedCount == captured.count:
            made.vmCode = site.code
        case .unsupported:
            made.vmCode = site.code
        case .untried:
            _ = compiled(made)
            site.code = made.vmCode
        case .code:
            break
        }
        return made
    }
}

extension Interpreter {
    /// The binding of `self` a closure the loop calls captured: a function of its own, so that the
    /// lookup is not made part of the loop.
    @inline(never)
    func capturedSelf() -> Binding? {
        lookup("self")
    }
}
