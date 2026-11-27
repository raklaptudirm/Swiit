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
    /// locals it names, and the values its capture list takes, each weakly if it says so.
    func makeClosure(
        _ site: ClosureSite,
        _ registers: UnsafeMutablePointer<Value>
    ) throws
        -> Value
    {
        let capture = Scope()
        for local in site.cells {
            capture.bindings[local.name] = Binding(
                cell: try cell(registers[Int(local.register)]),
                mutable: local.mutable
            )
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
        return .function(
            Function(
                name: nil,
                parameters: site.literal.parameters,
                returnType: site.literal.returnType,
                body: .swiit(site.literal.body),
                captured: captured
            )
        )
    }
}
