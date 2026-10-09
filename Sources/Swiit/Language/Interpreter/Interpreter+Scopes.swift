import Foundation
import SwishKit

extension Interpreter {
    @_spi(Shell) public func lookup(_ name: String) -> Binding? {
        scopeHolding(name)?.bindings[name]
    }

    /// The innermost scope binding `name`.
    @_spi(Shell) public func scopeHolding(_ name: String) -> Scope? {
        for scope in scopes.reversed() {
            if let holding = scope.holding(name) { return holding }
        }
        return nil
    }

    /// What a closure or nested function keeps of the scopes it's made in:
    /// the global ones, and only the local variables its body names, each
    /// shared with where it's declared. Keeping whole scopes would keep the
    /// one the closure itself is stored in: a cycle, never freed.
    @_spi(Shell) public func captureScopes(_ names: NamesUsed) -> [Scope] {
        guard scopes.count > 2 else { return scopes }
        let local = scopes[2...]
        let capture = Scope()
        for name in names.names {
            if let scope = local.last(where: { $0.holding(name) != nil })?.holding(name) {
                capture.bindings[name] = scope.bindings[name]
            }
        }
        capture.fallbacks = local.map { WeakScope(scope: $0) } + local.flatMap(\.fallbacks)
        return Array(scopes[..<2]) + [capture]
    }

    /// The functions a command name refers to, if it was declared with `func`.
    @_spi(Shell) public func commandFunctions(named name: String) -> OverloadSet? {
        guard let binding = lookup(name), binding.isFunction,
              case .function(let callable) = binding.value else { return nil }
        return callable as? OverloadSet
    }
}
