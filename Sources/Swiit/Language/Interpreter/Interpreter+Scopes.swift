import Foundation
import SwiitKit

extension Interpreter {
    @_spi(Host) public func lookup(_ name: String) -> Binding? {
        scopeHolding(name)?.bindings[name]
    }

    /// The innermost scope binding `name`.
    func scopeHolding(_ name: String) -> Scope? {
        for scope in scopes.reversed() {
            if let holding = scope.holding(name) { return holding }
        }
        return nil
    }

    /// What a closure or nested function keeps of the scopes it's made in:
    /// the global ones, and only the local variables its body names, each
    /// shared with where it's declared. Keeping whole scopes would keep the
    /// one the closure itself is stored in: a cycle, never freed.
    func captureScopes(_ names: NamesUsed) -> [Scope] {
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
}
