import SwiitKit

// Effects, as Swift has them for `async` (Docs/Design/async.md, "Types and
// effects"): a call to an `async` function is marked with `await`, and
// `await` is written in an async context (the top level, an `async`
// function, or a closure, which becomes async). A layer's waits, like the
// shell's `$(…)`, are blocking calls and bring no effect.

extension TypeChecker {
    /// A function's, a closure's, or the top level's effects so far.
    @_spi(Layer) public struct EffectContext {
        /// Whether `await` may be written here.
        @_spi(Layer) public var allowsAwait: Bool
        /// `async` once an `async` call is awaited here.
        @_spi(Layer) public var effect: Effect = .sync
        /// The functions called here by name without `await`.
        var unawaited: Set<String> = []

        @_spi(Layer) public init(allowsAwait: Bool) {
            self.allowsAwait = allowsAwait
        }
    }

    /// A call of `effect` here: an `async` one needs an `await` covering it.
    func effectSite(_ effect: Effect, _ what: String) throws {
        guard effect == .async else { return }
        guard awaitDepth > 0 else { throw TypeError("\(what) is async, but isn't marked with 'await'") }
        asyncSites += 1
        effectContexts[effectContexts.count - 1].effect = .async
    }

    /// A call to the function `name`, for the redefinition rule.
    func calledByName(_ name: String) {
        if awaitDepth == 0 { effectContexts[effectContexts.count - 1].unawaited.insert(name) }
    }

    /// `await` written here: allowed only in an async context.
    func checkAwaitAllowed() throws {
        guard effectContexts.last?.allowsAwait == true else {
            throw TypeError("'await' in a function that isn't async: declare it 'async'")
        }
    }

    /// Checks `body` in a context of its own, giving what waited in it.
    @_spi(Layer) public func withEffects<T>(allowsAwait: Bool, _ body: () throws -> T) rethrows -> (T, EffectContext) {
        effectContexts.append(EffectContext(allowsAwait: allowsAwait))
        let awaitBefore = awaitDepth
        awaitDepth = 0 // An `await` outside doesn't reach in.
        defer {
            effectContexts.removeLast()
            awaitDepth = awaitBefore
        }
        let result = try body()
        return (result, effectContexts[effectContexts.count - 1])
    }

    /// A function declared at the top level as `async` that was sync: refused
    /// while functions declared earlier call it without `await`, which they
    /// would have to (the redefinition rule).
    func checkBecomingAsync(_ decl: FunctionDecl) throws {
        guard decl.isAsync, effectContexts.count == 1 else { return }
        if let binding = interpreter.scopes.last?.bindings[decl.name], case .function(let set as OverloadSet) = binding.value,
           set.candidates.allSatisfy({ $0.effect == .async }) { return }
        let callers = (interpreter.unawaitedCallers[decl.name] ?? []).subtracting(redeclaredHere).sorted()
        guard !callers.isEmpty else { return }
        let list = callers.map { "'\($0)'" }.joined(separator: ", ")
        throw TypeError("\(decl.name) can't become async: \(list) call\(callers.count == 1 ? "s" : "") it without 'await'")
    }

    /// Who calls what without `await`, kept for the redefinition rule; what
    /// this program declares replaces what was declared before.
    func recordUnawaitedCalls() {
        for name in topLevelUnawaited.keys {
            for callee in interpreter.unawaitedCallers.keys { interpreter.unawaitedCallers[callee]?.remove(name) }
        }
        for (name, callees) in topLevelUnawaited {
            for callee in callees { interpreter.unawaitedCallers[callee, default: []].insert(name) }
        }
    }
}
