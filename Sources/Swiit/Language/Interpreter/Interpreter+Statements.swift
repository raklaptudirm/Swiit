import Foundation

extension Interpreter {
    // MARK: Statements

    /// Runs a program. A host that shows what a program gives, as the host
    /// does at the prompt and in scripts, passes an `observer`: it is told the
    /// value of each of the program's own expression statements. Statements
    /// nested in blocks, like the body of a `for`, aren't the program's own,
    /// as in Swift's REPL: use `print` for those.
    /// What it gives back is the value of the program's last statement when that is an expression
    /// that ran, and nothing otherwise.
    @discardableResult
    func run(
        _ program: Program,
        observing observer: ValueObserver? = nil,
        onError handle: ((Diagnostic) -> Bool)? = nil,
        finish: (() -> Void)? = nil
    ) throws -> Value {
        var result = Value.nothing
        try hoistDeclarations(program)
        // `defer` blocks run as the block ends, however it ends.
        var deferred: [Program] = []
        defer { runDeferred(deferred) }
        for (index, statement) in program.statements.enumerated() {
            result = .nothing
            if case .deferBlock(let body) = statement {
                deferred.append(body)
                continue
            }
            if statement.declaresType { continue }  // Hoisted.
            try checkInterrupt()
            do {
                if case .expression(let expression) = statement {
                    result =
                        if let observer {
                            try runObserved(expression, observer)
                        } else {
                            try runExpression(expression)
                        }
                } else {
                    try run(statement)
                }
            } catch let caught {
                var error = caught
                if var runtime = error as? RuntimeError, index < program.ranges.count {
                    if runtime.range == nil {
                        // The innermost statement is where it happened.
                        runtime.range = program.ranges[index]
                    } else if let last = runtime.calls.indices.last, runtime.calls[last].site == nil
                    {
                        // The statement the function was called from.
                        runtime.calls[last].site = program.ranges[index]
                    }
                    error = runtime
                }
                // The host may carry on with the next statement after an error a script could have
                // caught.
                if let handle,
                    error is RuntimeError || error is FatalError,
                    handle(Diagnostic.of(error))
                {
                    continue
                }
                throw error
            }
        }
        finish?()
        // Whatever the last statement let go of.
        if hasPendingDeinits { runPendingDeinits() }
        return result
    }

    /// The branch of an `if` its condition picks, with what the condition
    /// binds; nil for no `else`.
    func chooseBranch(_ node: IfStatement) throws -> (Program?, [String: Binding]) {
        if let bindings = try holds(node.condition) { return (node.then, bindings) }
        return (node.otherwise, [:])
    }

    /// What an `if` or `guard` condition binds when it holds; nil when it doesn't.
    func holds(_ condition: IfStatement.Condition) throws -> [String: Binding]? {
        switch condition {
        case .pattern(let pattern, let expr):
            var bindings: [String: Binding] = [:]
            return try match(pattern, try evaluate(expr), into: &bindings) ? bindings : nil
        case .expression(let expr):
            return try isTrue(expr) ? [:] : nil
        case .binding(let name, let mutable, let expr):
            let value = try evaluate(expr)
            return value != .nothing ? [name: Binding(value: value, mutable: mutable)] : nil
        }
    }

    /// A condition's value.
    func isTrue(_ condition: Expr) throws -> Bool {
        let value = try evaluate(condition)
        guard case .bool(let truth) = value.storage else {
            throw RuntimeError("condition must be a Bool, not \(value.typeName)")
        }
        return truth
    }

    /// Declares a block's functions and types before it runs, so they can
    /// be used before their declarations, as in Swift. A function is
    /// declared again where it's written, which captures what's been
    /// declared by then, as it always has.
    func hoistDeclarations(_ program: Program) throws {
        for statement in program.statements {
            if case .function = statement {
                try run(statement)
            } else if statement.declaresType, case .typeExtension = statement {
            } else if statement.declaresType {
                try run(statement)
            }
        }
        // What extensions add comes once the types are there to be made.
        for statement in program.statements {
            if case .typeExtension = statement { try run(statement) }
        }
    }

    /// Deferred blocks, last first. One that fails is reported; the rest
    /// still run, as nothing can leave a `defer`. What they run isn't told to
    /// the host: cleaning up doesn't change how the block went.
    func runDeferred(_ blocks: [Program]) {
        let observing = observesStatements
        observesStatements = false
        defer { observesStatements = observing }
        for body in blocks.reversed() {
            do {
                try runBlock(body)
            } catch let error as RuntimeError {
                report("error: \(error)")
            } catch {
                report("error: \(error)")
            }
        }
    }

    func runBlock(_ program: Program, declaring bindings: [String: Binding] = [:]) throws {
        // A block of a body given a frame that binds nothing needs nothing made for it.
        if program.locals?.isEmpty == true, bindings.isEmpty {
            _ = try run(program)
            return
        }
        guard let locals = program.locals, let frame = task.frame else {
            scopes.append(Scope(bindings))
            defer { scopes.removeLast() }
            try run(program)
            return
        }
        // A block of a body given a frame: what it begins with goes in the slots it was given.
        for (name, binding) in bindings {
            guard let local = locals.first(where: { $0.name == name }) else {
                preconditionFailure("\(name) was given no slot in its block")
            }
            frame.bind(name, binding, at: local.slot)
        }
        defer { frame.clear(locals) }
        try run(program)
    }

    func run(_ statement: Statement) throws {
        switch statement {
        case .typeExtension(let decl):
            try declare(decl)
        case .operatorDeclaration(let key, let source):
            declaredOperators[key] = source
        case .protocolDecl(let decl):
            try declare(decl)
        case .classDecl(let decl):
            try declare(decl)
        case .extensionDecl, .deferBlock:
            // The prelude's, read at startup; collected by the block that holds it.
            return
        case .declare(let name, let mutable, let expr):
            let value = try evaluate(expr)
            if name != "_" {
                scopes[scopes.count - 1].bindings[name] = Binding(value: value, mutable: mutable)
            }
        case .declareLocal(let local, let mutable, let expr):
            let value = try evaluate(expr)
            task.frame!.bind(local.name, Binding(value: value, mutable: mutable), at: local.slot)
        case .assign(let assignment):
            try assign(assignment)
        case .structDecl(let decl):
            try declare(decl)
        case .function(let decl):
            // Captures the scope it's bound in, so it can call itself.
            let function = Function(
                name: decl.name,
                parameters: decl.parameters,
                returnType: decl.returnType,
                body: .swiit(decl.body),
                captured: captureScopes(decl.names),
                documentation: decl.documentation,
                attributes: decl.attributes,
                isThrowing: decl.isThrowing,
                effect: decl.effect,
                typeParameters: decl.runtimeTypeParameters
            )
            // A function of a builtin's name overloads it: `print(_ p: Point)` beside
            // `print(_ items: Any...)`.
            let current = scopes[scopes.count - 1]
            if current.bindings[decl.name] == nil, scopes.count > 1,
                let builtin = scopes[0].bindings[decl.name],
                builtin.isFunction
            {
                current.bindings[decl.name] = builtin
            }
            current.declare(function, named: decl.name)
        case .enumDecl(let decl):
            try declare(decl)
        case .expression(let expr):
            let value = try evaluate(expr)
            finished(statement, value)
            return
        // What runs inside these says how they went, and a body that doesn't
        // run leaves them as a statement that did nothing.
        case .doCatch(let body, let clauses):
            finished(statement, nil)
            do {
                try runBlock(body)
            } catch let error as RuntimeError {
                guard let (index, bindings) = try firstMatch(clauses, error.value, anyName: "error")
                else {
                    throw error
                }
                try runBlock(clauses[index].body, declaring: bindings)
            }
            return
        case .throwStatement(let expr):
            let value = try evaluate(expr)
            // What the error says is its `description`, if it is a CustomStringConvertible, as `print` shows it.
            throw RuntimeError((try? describing(value)) ?? value.description, thrown: value)
        case .ifStatement(let node):
            finished(statement, nil)
            let (branch, bindings) = try chooseBranch(node)
            if let branch { try runBlock(branch, declaring: bindings) }
            return
        case .switchStatement(let node):
            finished(statement, nil)
            try runSwitch(node)
            return
        case .forLoop(let loop):
            finished(statement, nil)
            try forEachElement(of: loop.sequence, awaiting: loop.isAwait) { element in
                var bindings: [String: Binding] = [:]
                guard try match(loop.pattern, element, into: &bindings) else {
                    throw RuntimeError("a \(element.typeName) doesn't fit this 'for' pattern")
                }
                return try runLoopBody(loop.body, declaring: bindings, label: loop.label)
            }
            return
        case .whileLoop(let loop):
            finished(statement, nil)
            if loop.isRepeat {
                repeat {
                    guard try runLoopBody(loop.body, declaring: [:], label: loop.label) else {
                        break
                    }
                } while try isTrue(loop.condition)
                return
            }
            while try isTrue(loop.condition) {
                guard try runLoopBody(loop.body, declaring: [:], label: loop.label) else { break }
            }
            return
        case .fallthroughStatement:
            throw ControlFlow.fallthroughCase
        case .guardStatement(let condition, let otherwise):
            if let bindings = try holds(condition) {
                for (name, binding) in bindings {
                    scopes[scopes.count - 1].bindings[name] = binding
                }
                return
            }
            try runBlock(otherwise)
            // The checker sees to it that the else leaves; `exit` might not
            // (with jobs left, it only warns).
            throw RuntimeError("guard's else carried on")
        case .returnStatement(let expr):
            // A `.case` returned from a function declared to return an enum.
            throw ControlFlow.returned(
                try expr.map { try evaluate($0, expecting: returnTypes.last ?? nil) } ?? .nothing
            )
        case .breakStatement(let label):
            throw ControlFlow.breakLoop(label)
        case .continueStatement(let label):
            throw ControlFlow.continueLoop(label)
        }
        finished(statement, nil)
    }

    /// An expression statement at the top level: evaluated, and shown to the
    /// observer (unless it is a bare `true` or `false`, which stand in for the
    /// Unix commands).
    /// An expression statement: its value, with the host told it finished.
    func runExpression(_ expr: Expr) throws -> Value {
        let value = try evaluate(expr)
        finished(.expression(expr), value)
        return value
    }

    func runObserved(_ expr: Expr, _ observer: ValueObserver) throws -> Value {
        task.lastCallee = nil
        let value = try evaluate(expr)
        let isBoolLiteral = if case .literal(let value) = expr, value.isBool { true } else { false }
        if !isBoolLiteral { try observer(value, calleeSymbol(of: expr)) }
        finished(.expression(expr), value)
        return value
    }

    /// Runs one iteration; false means `break`. A `break` or `continue` that
    /// names another loop goes on to it.
    func runLoopBody(
        _ body: Program,
        declaring bindings: [String: Binding],
        label: String? = nil
    ) throws -> Bool {
        try checkInterrupt()
        do {
            try runBlock(body, declaring: bindings)
        } catch ControlFlow.breakLoop(let named) where named == nil || named == label {
            return false
        } catch ControlFlow.continueLoop(let named) where named == nil || named == label {}
        return true
    }

    /// Iterates lists, ranges lazily (so `for i in 1...1_000_000_000` never
    /// builds a list), strings by character, as in Swift, the Swift
    /// sequences Swiit holds, and command output by line.
    func forEachElement(
        of sequence: Expr,
        awaiting: Bool = false,
        _ body: (Value) throws -> Bool
    ) throws {
        if case .binary(let op, let lower, let upper) = sequence,
            op == .closedRange || op == .halfOpenRange
        {
            for i in try intRange(op, try evaluate(lower), try evaluate(upper)) {
                guard try body(.int(i)) else { return }
            }
            return
        }
        let value = try evaluate(sequence)
        if let read = Interpreter.taskGroupReader(of: value) {
            while let element = try read() {
                guard try body(element) else { return }
            }
            return
        }
        let elements: AnyIterator<Value>
        if case .dictionary(let dictionary) = value.storage {
            // In the order they are shown in, which is the same every run.
            elements = AnyIterator(
                dictionary.sortedForDisplay
                    .map { entry in
                        Value(record: Value.Record(["key": entry.key, "value": entry.value]))
                    }
                    .makeIterator()
            )
        } else if case .string(let text) = value.storage {
            elements = AnyIterator(text.lazy.map { .string(String($0)) }.makeIterator())
        } else if let items = Interpreter.items(of: value) {
            elements = items
        } else if let next = try iterator(of: value, awaiting: awaiting) {
            while let element = try next() {
                guard try body(element) else { return }
            }
            return
        } else {
            throw RuntimeError("can't iterate over \(value.typeName)")
        }
        for element in elements {
            guard try body(element) else { return }
        }
    }

    /// What `for` reads a value with when it declares its own iteration, as Swift's protocols say:
    /// the `next()` of its `makeIterator()` (`makeAsyncIterator()` for `for await`), which gives nil
    /// when the items are done; nil if the value has no such iterator.
    func iterator(of value: Value, awaiting: Bool) throws -> (() throws -> Value?)? {
        guard
            let make = try? member(awaiting ? "makeAsyncIterator" : "makeIterator", of: value)
        else {
            return nil
        }
        let iterator = try call(make, with: [])
        let next = try member("next", of: iterator)
        return {
            let item = try self.call(next, with: [])
            if case .nothing = item.storage { return nil }
            return item
        }
    }

    /// Throws if the script should stop: it was cancelled, the host asked it to, or a limit is
    /// reached. A host function that waits calls it between waits, so a stop is noticed while it
    /// does.
    public func checkForStop() throws { try checkInterrupt() }

    func checkInterrupt() throws {
        if hasPendingDeinits { runPendingDeinits() }
        steps += 1
        // A task that is cancelled stops at its next step, even before it has begun: that is every
        // step's.
        if cancellation.isSet { throw Cancelled() }
        // The rest is asked every few steps, not every one: one count down is all most steps pay.
        stepsUntilCheck -= 1
        if stepsUntilCheck <= 0 { try checkLimits() }
    }

    /// How many steps go by between asking the host whether to stop and checking the limits: few
    /// enough that a stop or a deadline is seen within microseconds.
    static let stepsBetweenChecks = 16

    /// Asks the host whether to stop, checks the limits, and says when to do so again: in a few
    /// steps, or at the step limit if that comes first, so a run stops at exactly its limit.
    func checkLimits() throws {
        if task.receivesInterrupts, let reason = host.interrupt() {
            throw Interrupted(reason: reason)
        }
        if let deadline, ContinuousClock.now > deadline {
            throw LimitExceeded("time limit exceeded")
        }
        if let maximum = limits.maxOutputBytes, outputCounter.written > maximum {
            throw LimitExceeded("output limit (\(maximum) bytes) exceeded")
        }
        stepsUntilCheck = Interpreter.stepsBetweenChecks
        if let maximum = limits.maxSteps {
            if steps > maximum { throw LimitExceeded("step limit (\(maximum)) exceeded") }
            stepsUntilCheck = min(stepsUntilCheck, maximum - steps + 1)
        }
    }
}

/// Told the value of each top-level expression statement: the value, the
/// expression it came from, and whether Swift would discard it
/// (`@discardableResult`).
/// Told each simple statement as it finishes: the statement, an expression
/// statement's value, and whether a per-item error was reported while it ran.
/// An `if`, a loop, a `switch` and a `do` are told as they start, with no
/// value; the statements in them are told as they run. The host keeps the
/// exit status from these.
typealias StatementObserver = (_ statement: Statement, _ value: Value?, _ itemErrors: Bool) -> Void

extension Interpreter {
    /// Tells the host a statement finished, if it is watching
    /// (`Interpreter.Host.didFinishStatement`).
    func finished(_ statement: Statement, _ value: Value?) {
        guard observesStatements, let observer = host.didFinishStatement else { return }
        // A `try?` that caught an error gave nil because it failed; other nils, like a function
        // that returns nothing, didn't.
        var caught = false
        if value == .nothing, case .expression(.attempt(_, .optional)) = statement { caught = true }
        observer(value, caught)
    }
}

typealias ValueObserver = (_ value: Value, _ callee: Symbol?) throws -> Void

extension Interpreter {
    /// The function an expression statement just called, when the statement is a call (through the
    /// `try`, `await` and `!` around it): what a host asks for its attributes, such as
    /// `@discardableResult`.
    func calleeSymbol(of expression: Expr) -> Symbol? {
        var expression = expression
        while true {
            switch expression {
            case .attempt(let inner, _), .await(let inner, _), .forceUnwrap(let inner),
                .specialized(let inner, _), .chosen(let inner, _), .described(let inner, _),
                .annotated(let inner, _), .voidValue(let inner):
                expression = inner
            case .bridged(let type, let member, _, _):
                guard let found = Bridge.types[type]?.members[member] else { return nil }
                return bridgedSymbol(found, checker: TypeChecker(interpreter: self))
            case .call:
                return task.lastCallee.map { symbol(of: $0, named: "closure") }
            default:
                return nil
            }
        }
    }
}
