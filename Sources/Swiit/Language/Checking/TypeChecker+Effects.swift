import SwishKit

// Effects, as Swift has them for `async` (Docs/Design/async.md, "Types and
// effects"): a call to an `async` function is marked with `await`, and
// `await` is written in an async context (the top level, an `async`
// function, or a closure, which becomes async). What waits only through a
// layer's constructs (the shell's `$(…)` and commands) is implicitly async:
// it is called with no `await`, and so is anything that calls it.

extension TypeChecker {
    /// A function's, a closure's, or the top level's effects so far.
    @_spi(Shell) public struct EffectContext {
        /// Whether `await` may be written here.
        @_spi(Shell) public var allowsAwait: Bool
        /// What has waited here so far.
        @_spi(Shell) public var effect: Effect = .sync
        /// The functions called here by name, and those called without `await`.
        @_spi(Shell) public var callees: Set<String> = []
        @_spi(Shell) public var unawaited: Set<String> = []

        @_spi(Shell) public init(allowsAwait: Bool) {
            self.allowsAwait = allowsAwait
        }
    }

    /// Something that waits, as `effect` says, here: an `async` one needs an
    /// `await` covering it.
    @_spi(Shell) public func effectSite(_ effect: Effect, _ what: String) throws {
        guard effect.waits else { return }
        if effect == .async {
            guard awaitDepth > 0 else { throw TypeError("\(what) is async, but isn't marked with 'await'") }
            asyncSites += 1
        }
        effectContexts[effectContexts.count - 1].effect = effectContexts[effectContexts.count - 1].effect.joined(effect)
    }

    /// A call to the function `name`, for the call graph.
    @_spi(Shell) public func calledByName(_ name: String) {
        effectContexts[effectContexts.count - 1].callees.insert(name)
        if awaitDepth == 0 { effectContexts[effectContexts.count - 1].unawaited.insert(name) }
    }

    /// `await` written here: allowed only in an async context.
    @_spi(Shell) public func checkAwaitAllowed() throws {
        guard effectContexts.last?.allowsAwait == true else {
            throw TypeError("'await' in a function that isn't async: declare it 'async'")
        }
    }

    /// Checks `body` in a context of its own, giving what waited in it.
    @_spi(Shell) public func withEffects<T>(allowsAwait: Bool, _ body: () throws -> T) rethrows -> (T, EffectContext) {
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
    @_spi(Shell) public func checkBecomingAsync(_ decl: FunctionDecl) throws {
        guard decl.isAsync, effectContexts.count == 1 else { return }
        if let binding = interpreter.scopes.last?.bindings[decl.name], case .function(let set as OverloadSet) = binding.value,
           set.candidates.allSatisfy({ $0.effect == .async }) { return }
        let callers = (interpreter.unawaitedCallers[decl.name] ?? []).subtracting(redeclaredHere).sorted()
        guard !callers.isEmpty else { return }
        let list = callers.map { "'\($0)'" }.joined(separator: ", ")
        throw TypeError("\(decl.name) can't become async: \(list) call\(callers.count == 1 ? "s" : "") it without 'await'")
    }

    /// The top-level functions of a checked program, each as implicitly async
    /// as what it calls: a function can call one declared after it, which
    /// wasn't known to wait when the call was checked.
    @_spi(Shell) public func settleEffects(_ program: inout Program) {
        var effects: [String: Effect] = [:]
        for statement in program.statements { if case .function(let decl) = statement { effects[decl.name] = decl.effect } }
        var changed = true
        while changed {
            changed = false
            for (name, callees) in topLevelCalls where effects[name] == .sync {
                if callees.contains(where: { effects[$0]?.waits == true }) {
                    effects[name] = .implicitAsync
                    changed = true
                }
            }
        }
        for index in program.statements.indices {
            if case .function(var decl) = program.statements[index], let effect = effects[decl.name], effect != decl.effect {
                decl.effect = effect
                program.statements[index] = .function(decl)
            }
        }
        // Who calls what without `await`, for the redefinition rule; what this
        // program declares replaces what was declared before.
        for name in topLevelCalls.keys {
            for callee in interpreter.unawaitedCallers.keys { interpreter.unawaitedCallers[callee]?.remove(name) }
        }
        for (name, callees) in topLevelUnawaited {
            for callee in callees { interpreter.unawaitedCallers[callee, default: []].insert(name) }
        }
    }
}
