import Foundation
import SwiitKit

extension Interpreter {
    // MARK: Calls

    /// Whether two values are of the same kind: a plain one is told by its case, without building the name of its type.
    static func sameKind(_ a: Value, _ b: Value) -> Bool {
        switch (a, b) {
        case (.int, .int), (.double, .double), (.string, .string), (.bool, .bool), (.list, .list), (.dictionary, .dictionary): true
        case (.int, _), (.double, _), (.string, _), (.bool, _), (.list, _), (.dictionary, _): false
        default: a.typeName == b.typeName
        }
    }

    /// Runs `function` with its parameters bound to `arguments`.
    /// Calls `function`. A method gets `receiver` as `self`, and leaves it
    /// there as the method changed it.
    public func invoke(_ function: Function, with arguments: [String: Value], receiver: Receiver? = nil) throws -> Value {
        guard callDepth < limits.depth else {
            throw RuntimeError("maximum call depth (\(limits.depth)) exceeded")
        }
        try checkInterrupt()
        switch function.body {
        case .native(let body):
            // A method in Swift gets its receiver as `self`, and runs where it
            // is called from, as any builtin does.
            guard let receiver else { return try body(self, arguments) }
            var arguments = arguments
            arguments["self"] = receiver.value
            return try body(self, arguments)
        case .stream(let transform):
            // Called directly: the input is a list, and so is the result.
            let input = function.inputParameter.flatMap { arguments[$0.name] } ?? .list([])
            let output = try transform(self, .elements(of: input), arguments)
            var items: [Value] = []
            while let item = try output.next() { items.append(item) }
            return .list(items)
        case .swiit:
            break
        }

        let savedScopes = scopes
        let inouts = Set(function.parameters.filter(\.isInout).map(\.name))
        var made = [String: Binding](minimumCapacity: arguments.count + 1)
        for argument in arguments { made[argument.key] = Binding(value: argument.value, mutable: inouts.contains(argument.key)) }
        let argumentScope = Scope(made)
        // A type parameter the call left to what was passed (a protocol's type) is the type of that value, as Swift opens an existential.
        for name in function.typeParameters {
            if case .object(let bound)? = function.captured.last?.bindings[Interpreter.typeArgumentPrefix + name]?.value, !(bound is ProtocolType) { continue }
            guard let parameter = function.parameters.first(where: { $0.type == .parameter(name) }), let argument = arguments[parameter.name] else { continue }
            let actual = typeObject(of: argument)
            guard actual != .nothing else { continue }
            argumentScope.bindings[name] = Binding(value: actual, mutable: false)
            argumentScope.bindings[Interpreter.typeArgumentPrefix + name] = Binding(value: actual, mutable: false)
        }
        if let receiver {
            argumentScope.bindings["self"] = Binding(
                value: receiver.value, mutable: receiver.mutable, special: receiver.initializing ? .initializing : nil
            )
        }
        // A nested function reaches itself through the call, not by keeping
        // the binding it's stored in, which would be a cycle.
        if let name = function.name, function.captured.count > 2, argumentScope.bindings[name] == nil,
           case .swiit = function.body {
            argumentScope.bindings[name] = Binding(
                value: .function(OverloadSet(name: name, candidates: [function])), mutable: false, isFunction: true
            )
        }
        var inside = [Scope]()
        inside.reserveCapacity(function.captured.count + 1)
        inside.append(contentsOf: function.captured)
        inside.append(argumentScope)
        scopes = inside
        if let owner = function.owner { task.owners.append(owner) }
        callDepth += 1
        returnTypes.append(function.returnType)
        defer {
            if let receiver, let changed = argumentScope.bindings["self"]?.value { receiver.value = changed }
            scopes = savedScopes
            if function.owner != nil { task.owners.removeLast() }
            callDepth -= 1
            returnTypes.removeLast()
            // What the call started ends with it, however it ends.
            if let last = task.children.last, last.depth > callDepth { closeTasks(above: callDepth) }
        }

        let result: Value
        if let expr = function.implicitReturn {
            result = try evaluate(expr, expecting: function.returnType)
        } else {
            guard case .swiit(let body) = function.body else { preconditionFailure() }
            do {
                _ = try run(body)
                result = .nothing
            } catch ControlFlow.returned(let value) {
                result = value
                if function.isFailable && value == .nothing { task.failedInit = true }
            } catch var error as RuntimeError {
                // Unwinding out of a function: the statement that called it will say where.
                error.calls.append(RuntimeError.Call(function: function.name ?? "a closure", site: nil))
                throw error
            }
        }

        // What the `inout` parameters hold now goes back to where the call took them from.
        if !inouts.isEmpty {
            task.inoutOutputs = function.parameters.filter(\.isInout).map { argumentScope.bindings[$0.name]?.value ?? .nothing }
        }
        guard let returnType = function.returnType else { return result }
        guard let conforming = conform(result, to: returnType) else {
            let what = result == .nothing ? "nothing" : result.typeName
            throw RuntimeError("\(function.name ?? "closure") must return \(returnType), but returned \(what)")
        }
        return conforming
    }

    /// Calls a function value with positional arguments, as builtins like
    /// `where` call the closures they're given.
    public func call(_ value: Value, with arguments: [Value]) throws -> Value {
        let unlabeled = arguments.map { Argument(label: nil, value: .literal($0)) }
        switch value {
        case .function(let set as OverloadSet):
            let (function, bindings) = try resolve(set) { try self.bind(unlabeled, to: $0) }
            return try invoke(function, with: bindings)
        case .function(let function as Function):
            return try invoke(function, with: try bind(unlabeled, to: function).bindings)
        case .function(let native as NativeFunction):
            let function = hostFunction(native.function)
            return try invoke(function, with: try bind(unlabeled, to: function).bindings)
        case .function(let keyPath as KeyPathValue):
            guard arguments.count == 1 else { throw RuntimeError("a key path reads one value") }
            return try keyPath.read(from: arguments[0], in: self)
        default:
            throw RuntimeError("\(value.typeName) isn't a function")
        }
    }

    /// A closure last and unlabeled can go to a labeled parameter, as a
    /// trailing closure does in Swift (`xs.sorted { $0.x < $1.x }` for
    /// `by:`), unless a later unlabeled parameter is waiting for it.
    func isTrailingClosure(
        _ arguments: [Argument], at index: Int, for parameter: Parameter, before later: ArraySlice<Parameter>
    ) -> Bool {
        guard index == arguments.count - 1, arguments[index].label == nil, parameter.label != nil,
              later.allSatisfy({ $0.label != nil }) else { return false }
        switch arguments[index].value {
        case .closure, .literal(.function): return parameter.type.acceptsFunction
        default: return false
        }
    }

    /// Matches expression-mode arguments to parameters by Swift's rules:
    /// in order, labels must match, defaulted parameters may be skipped.
    ///
    /// The penalty counts conversions and untyped parameters, so overload
    /// resolution can prefer the most specific match.
    @_spi(Layer) public func bind(_ arguments: [Argument], to function: Function) throws -> (bindings: [String: Value], penalty: Int) {
        let name = function.name ?? "closure"
        var bound: [String: Value] = [:]
        var penalty = 0
        func checked(_ value: Value, for parameter: Parameter) throws -> Value {
            let result = try self.checked(value, for: parameter, of: name)
            if parameter.type == .any || !Interpreter.sameKind(result, value) || !result.isEqual(to: value) { penalty += 1 }
            return result
        }
        var index = 0
        for (position, parameter) in function.parameters.enumerated() {
            if index < arguments.count, arguments[index].label == parameter.label
                || isTrailingClosure(arguments, at: index, for: parameter, before: function.parameters[(position + 1)...]) {
                if parameter.variadic {
                    var values: [Value] = []
                    repeat {
                        values.append(try evaluate(arguments[index].value, expecting: parameter.type))
                        index += 1
                    } while index < arguments.count && arguments[index].label == nil
                    bound[parameter.name] = try checked(.list(values), for: parameter)
                } else {
                    bound[parameter.name] = try checked(try evaluate(arguments[index].value, expecting: parameter.type), for: parameter)
                    index += 1
                }
            } else if parameter.variadic {
                bound[parameter.name] = .list([])
            } else if let defaultValue = parameter.defaultValue {
                bound[parameter.name] = try defaultArgument(defaultValue, for: parameter, of: function)
            } else if parameter.externalDefault != nil {
                continue // The Swift function fills it in.
            } else {
                let label = parameter.label.map { "'\($0):'" } ?? "#\(function.parameters.firstIndex(of: parameter)! + 1)"
                throw RuntimeError("\(name): missing argument \(label)")
            }
        }
        guard index == arguments.count else {
            let extra = arguments[index].label.map { "'\($0):'" } ?? "#\(index + 1)"
            throw RuntimeError("\(name): unexpected argument \(extra)")
        }
        return (bound, penalty)
    }

    /// Defaults are evaluated at call time, in the scope the function was defined in.
    @_spi(Layer) public func defaultArgument(_ expr: Expr, for parameter: Parameter, of function: Function) throws -> Value {
        let savedScopes = scopes
        scopes = function.captured
        defer { scopes = savedScopes }
        return try checked(try evaluate(expr, expecting: parameter.type), for: parameter, of: function.name ?? "closure")
    }

    public func checked(_ value: Value, for parameter: Parameter, of function: String) throws -> Value {
        let type = parameter.variadic ? TypeAnnotation.list(parameter.type) : parameter.type
        guard let conforming = conform(value, to: type) else {
            throw RuntimeError("\(function): '\(parameter.name)' must be \(type), not \(value.typeName)")
        }
        return conforming
    }
}

/// `set` with only the overload the checker chose, when it did.
public func narrowed(_ set: OverloadSet, _ overload: Int?) -> OverloadSet {
    guard let overload, set.candidates.indices.contains(overload) else { return set }
    return OverloadSet(name: set.name, candidates: [set.candidates[overload]])
}

extension Interpreter {
    // MARK: Overloads

    /// Picks the overload that `bind` accepts with the lowest penalty, the
    /// most specific match. Ties are an error, never a guess.
    public func resolve(
        _ set: OverloadSet, _ bind: (Function) throws -> (bindings: [String: Value], penalty: Int)
    ) throws -> (Function, [String: Value]) {
        if set.candidates.count == 1 {
            return (set.candidates[0], try bind(set.candidates[0]).bindings)
        }
        var matches: [(function: Function, bindings: [String: Value], penalty: Int)] = []
        for candidate in set.candidates {
            do {
                let (bindings, penalty) = try bind(candidate)
                matches.append((candidate, bindings, penalty))
            } catch is RuntimeError {
                continue
            }
        }
        guard let best = matches.map(\.penalty).min() else {
            throw RuntimeError("\(set.name): no overload accepts these arguments; candidates:\n"
                + set.candidates.map { "  " + $0.signature }.joined(separator: "\n"))
        }
        var bestMatches = matches.filter { $0.penalty == best }
        // Of equals, a function that takes a type itself beats one generic in it, as in Swift.
        if bestMatches.count > 1 {
            let generic = { (function: Function) in function.parameters.filter { if case .parameter = $0.type { true } else { false } }.count }
            let fewest = bestMatches.map { generic($0.function) }.min()!
            bestMatches = bestMatches.filter { generic($0.function) == fewest }
        }
        guard bestMatches.count == 1 else {
            throw RuntimeError("\(set.name): ambiguous call; these overloads all match:\n"
                + bestMatches.map { "  " + $0.function.signature }.joined(separator: "\n"))
        }
        return (bestMatches[0].function, bestMatches[0].bindings)
    }
}

extension Interpreter {
    /// A host's Swift function as a Swiit one: the same binding, help and
    /// streaming as a Swiit `func`.
    public func hostFunction(_ export: ExportedFunction) -> Function {
        let parameters = export.parameters.map { parameter in
            Parameter(
                label: parameter.label, name: parameter.name, type: TypeAnnotation(parameter.type),
                variadic: parameter.variadic, defaultValue: parameter.defaultValue.map(Expr.literal),
                isInput: parameter.isInput, shortFlag: parameter.shortFlag, externalDefault: parameter.defaultSource
            )
        }
        var docs: [String: String] = [:]
        for parameter in export.parameters {
            if let doc = parameter.documentation { docs[parameter.name] = doc }
        }
        let name = export.name
        let call = export.call
        return Function(
            name: name, parameters: parameters, returnType: export.returnType.map(TypeAnnotation.init),
            body: .native { _, arguments in
                do {
                    return try call(arguments)
                } catch let error as RuntimeError {
                    throw error
                } catch {
                    throw RuntimeError("\(name): \(error)")
                }
            },
            documentation: Documentation(summary: export.summary ?? "", parameters: docs),
            isThrowing: export.isThrowing
        )
    }
}

extension TypeAnnotation {
    public init(_ type: SwiitType) {
        self = switch type {
        case .any: .any
        case .bool: .bool
        case .int: .int
        case .double: .double
        case .string: .string
        case .record: .record
        case .filesize: .named("FileSize")
        case .date: .named("Date")
        case .output: .output
        case .function: .function
        case .named(let name): .named(name)
        case .list(let element): .list(TypeAnnotation(element))
        case .optional(let wrapped): .optional(TypeAnnotation(wrapped))
        @unknown default: .any
        }
    }
}

extension Interpreter {
    /// Calls a closure of two values whose first it changes in place (`reduce(into:)`'s), giving what it left in the first.
    func callChangingFirst(_ value: Value, _ first: Value, _ second: Value) throws -> Value {
        guard case .function(let function as Function) = value, !function.parameters.isEmpty else {
            return try { _ = try call(value, with: [first, second]); return first }()
        }
        var parameters = function.parameters
        parameters[0].isInout = true
        let changing = Function(
            name: function.name, parameters: parameters, returnType: function.returnType, body: function.body,
            captured: function.captured, documentation: function.documentation, isMutating: function.isMutating,
            isThrowing: function.isThrowing, isRethrowing: function.isRethrowing, effect: function.effect, generics: function.generics
        )
        let unlabeled = [first, second].map { Argument(label: nil, value: .literal($0)) }
        _ = try invoke(changing, with: try bind(unlabeled, to: changing).bindings)
        let outputs = task.inoutOutputs
        task.inoutOutputs = []
        return outputs.first ?? first
    }
}
