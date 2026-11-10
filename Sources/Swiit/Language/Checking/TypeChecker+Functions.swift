import Foundation

// Checking function declarations: their parameters, bodies and whether every path returns.

extension TypeChecker {
    /// Adds `decl` to its name's overloads, in the order the interpreter
    /// keeps them: one with the same parameters replaces the old.
    func declareFunction(_ decl: FunctionDecl) {
        var overloads: [Signature] = []
        if case .functions(let existing)? = scopes[scopes.count - 1][decl.name] {
            overloads = existing
        } else if scopes.count == 1, let binding = interpreter.scopes.last?.bindings[decl.name],
            binding.isFunction,
            case .function(let set as OverloadSet) = binding.value.storage
        {
            // At the top, it joins what earlier entries declared.
            overloads = set.candidates.map(signature)
        } else if scopes.count == 1, let binding = interpreter.scopes.first?.bindings[decl.name],
            binding.isFunction,
            case .function(let set as OverloadSet) = binding.value.storage
        {
            // A builtin of that name is overloaded, not replaced.
            overloads = set.candidates.map(signature)
        }
        overloads.removeAll {
            sameParameters($0.parameters, decl.parameters) && $0.generics == decl.generics
        }
        var declared = Signature(
            name: decl.name,
            parameters: decl.parameters,
            returns: decl.returnType ?? .void,
            isThrowing: decl.isThrowing,
            isRethrowing: decl.isRethrowing,
            effect: decl.effect,
            generics: decl.generics
        )
        declared.thrownType = decl.thrownType
        declared.typeParameters = decl.runtimeTypeParameters
        overloads.append(declared)
        for index in overloads.indices { overloads[index].index = index }
        scopes[scopes.count - 1][decl.name] = .functions(overloads)
    }

    func sameParameters(_ a: [Parameter], _ b: [Parameter]) -> Bool {
        a.count == b.count
            && zip(a, b)
                .allSatisfy {
                    $0.label == $1.label && $0.type == $1.type && $0.variadic == $1.variadic
                }
    }

    /// A body written for the result builder `name`, as the plain code it stands for.
    func resultBuilt(_ body: Program, by name: String) throws -> Program {
        guard let info = structInfo(named: name) else {
            throw TypeError("@\(name) is not a result builder")
        }
        var transform = ResultBuilderTransform(
            builder: name,
            methods: Set(info.declared.staticMethods.keys)
        )
        do { return try transform.transform(body) } catch let error as SyntaxError {
            throw TypeError(error.description)
        }
    }

    func checkFunction(
        _ decl: inout FunctionDecl,
        self selfType: TypeAnnotation? = nil,
        mutating: Bool = false,
        initializing: Bool = false
    ) throws {
        if let builder = decl.resultBuilder {
            decl.body = try resultBuilt(decl.body, by: builder)
            decl.resultBuilder = nil
        }
        var names: [String: Symbol] = [:]
        for index in decl.parameters.indices {
            let parameter = decl.parameters[index]
            if decl.parameters[index].defaultValue != nil {
                try expect(
                    &decl.parameters[index].defaultValue!,
                    parameter.type,
                    "\(parameter.name)'s default"
                )
            }
            // A type parameter isn't known in the body: values of it can be used as any.
            let known = substitute(parameter.type, [:])
            names[parameter.name] = .variable(
                parameter.variadic ? .list(known) : known,
                mutable: parameter.isInout
            )
        }
        // A type parameter is a value in the body too (`T()`, `T.self`), of a type that isn't known
        // there.
        for parameter in decl.generics.map(\.name) where names[parameter] == nil {
            names[parameter] = .variable(.unknown, mutable: false)
        }
        if let selfType { names["self"] = .variable(selfType, mutable: mutating || initializing) }
        // `super` is the class above, as `self`.
        if case .named(let className)? = selfType, let info = structInfo(named: className),
            let parent = info.superclass
        {
            names["super"] = .variable(.named(parent), mutable: true)
        }
        if initializing { names[InternalName.initializing] = .variable(.void, mutable: false) }
        // `init?` may `return nil`.
        let result =
            decl.isFailable
            ? TypeAnnotation.optional(.void) : substitute(decl.returnType ?? .void, [:])
        try checkBecomingAsync(decl)
        let topLevel = effectContexts.count == 1
        returns.append(ReturnContext(declared: result))
        errorContexts.append(
            ErrorContext(
                handled: decl.isThrowing || decl.isRethrowing,
                boundary: .function(decl.name),
                thrown: decl.thrownType
            )
        )
        scopes.append(names)
        defer {
            returns.removeLast()
            errorContexts.removeLast()
            scopes.removeLast()
        }

        // `await` only in an `async` function.
        let (_, effects) = try withEffects(allowsAwait: decl.isAsync) { () throws in
            // A body that's one expression is the result, when there's one.
            if result != .void, var expr = implicitReturn(decl.body) {
                try expect(&expr, result, "\(decl.name)'s result")
                decl.body.statements[0] = .expression(expr)
                return
            }
            try checkBlock(&decl.body)
            if result != .void && result != .unknown && !decl.isFailable
                && !definitelyReturns(decl.body)
            {
                throw TypeError("\(decl.name) must return \(result) on every path")
            }
        }
        if topLevel { topLevelUnawaited[decl.name] = effects.unawaited }
    }

    func implicitReturn(_ body: Program) -> Expr? {
        guard body.statements.count == 1 else { return nil }
        switch body.statements[0] {
        case .expression(let expr): return expr
        // A body that's one `if` with one expression per branch is that
        // `if` as an expression, as in Swift.
        case .ifStatement(let node): return node.asExpression.map(Expr.ifExpression)
        default: return nil
        }
    }

    /// Whether running `program` always ends in a `return`: as simple as
    /// Swift's own check, from the last statement.
    func definitelyReturns(_ program: Program) -> Bool {
        definitelyLeaves(program, orExits: false)
    }

    /// Whether running `program` always leaves it: by `return`, or, with
    /// `orExits` (for a guard's `else`), by `break` or `continue`.
    func definitelyLeaves(_ program: Program, orExits: Bool) -> Bool {
        // Declarations after the last statement run nothing, as in Swift.
        guard
            let last = program.statements.last(where: {
                if case .function = $0 { return false }
                return !$0.declaresType
            })
        else { return false }
        let leaves = { (program: Program) in self.definitelyLeaves(program, orExits: orExits) }
        switch last {
        case .returnStatement:
            return true
        case .breakStatement, .continueStatement:
            return orExits
        case .doCatch(let body, let clauses):
            return leaves(body) && clauses.allSatisfy { leaves($0.body) }
        case .throwStatement:
            return true
        case .ifStatement(let node):
            guard let otherwise = node.otherwise else { return false }
            return leaves(node.then) && leaves(otherwise)
        case .switchStatement(let node):
            // A switch always matches (or fails), so every case returning is enough.
            return !node.cases.isEmpty && node.cases.allSatisfy { leaves($0.body) }
        // What never comes back.
        case .expression(.call(.variable("fatalError"), _)),
            .expression(.call(.variable("preconditionFailure"), _)):
            return true
        case .expression(.call(.variable(let name), _)):
            // Any function declared to return `Never`: the host's `exit`.
            guard case .functions(let overloads)? = lookup(name) else { return false }
            return overloads.allSatisfy { $0.returns == .named("Never") }
        default:
            return false
        }
    }
}
