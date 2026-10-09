import Foundation
import SwishKit

extension Interpreter {
    // MARK: Calls

    /// Runs `function` with its parameters bound to `arguments`.
    /// Calls `function`. A method gets `receiver` as `self`, and leaves it
    /// there as the method changed it.
    @_spi(Shell) public func invoke(_ function: Function, with arguments: [String: Value], receiver: Receiver? = nil) throws -> Value {
        guard callDepth < limits.depth else {
            throw RuntimeError("maximum call depth (\(limits.depth)) exceeded")
        }
        try checkInterrupt()
        switch function.body {
        case .native(let body):
            return try body(self, arguments)
        case .stream(let transform):
            // Called directly: the input is a list, and so is the result.
            let input = function.inputParameter.flatMap { arguments[$0.name] } ?? .list([])
            let output = try transform(self, .elements(of: input), arguments)
            var items: [Value] = []
            while let item = try output.next() { items.append(item) }
            return .list(items)
        case .swish:
            break
        }

        let savedScopes = scopes
        let argumentScope = Scope(arguments.mapValues { Binding(value: $0, mutable: false) })
        if let receiver {
            argumentScope.bindings["self"] = Binding(
                value: receiver.value, mutable: receiver.mutable, special: receiver.initializing ? .initializing : nil
            )
        }
        // A nested function reaches itself through the call, not by keeping
        // the binding it's stored in, which would be a cycle.
        if let name = function.name, function.captured.count > 2, argumentScope.bindings[name] == nil,
           case .swish = function.body {
            argumentScope.bindings[name] = Binding(
                value: .function(OverloadSet(name: name, candidates: [function])), mutable: false, isFunction: true
            )
        }
        scopes = function.captured + [argumentScope]
        callDepth += 1
        returnTypes.append(function.returnType)
        defer {
            if let receiver, let changed = argumentScope.bindings["self"]?.value { receiver.value = changed }
            scopes = savedScopes
            callDepth -= 1
            returnTypes.removeLast()
        }

        let result: Value
        if let expr = function.implicitReturn {
            result = try evaluate(expr, expecting: function.returnType)
        } else {
            guard case .swish(let body) = function.body else { preconditionFailure() }
            do {
                _ = try run(body)
                result = .nothing
            } catch ControlFlow.returned(let value) {
                result = value
            }
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
    @_spi(Shell) public func call(_ value: Value, with arguments: [Value]) throws -> Value {
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
    @_spi(Shell) public func isTrailingClosure(
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
    @_spi(Shell) public func bind(_ arguments: [Argument], to function: Function) throws -> (bindings: [String: Value], penalty: Int) {
        let name = function.name ?? "closure"
        var bound: [String: Value] = [:]
        var penalty = 0
        func checked(_ value: Value, for parameter: Parameter) throws -> Value {
            let result = try self.checked(value, for: parameter, of: name)
            if parameter.type == .any || !result.isEqual(to: value) || result.typeName != value.typeName { penalty += 1 }
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
                continue // The plugin fills it in.
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
    @_spi(Shell) public func defaultArgument(_ expr: Expr, for parameter: Parameter, of function: Function) throws -> Value {
        let savedScopes = scopes
        scopes = function.captured
        defer { scopes = savedScopes }
        return try checked(try evaluate(expr, expecting: parameter.type), for: parameter, of: function.name ?? "closure")
    }

    @_spi(Shell) public func checked(_ value: Value, for parameter: Parameter, of function: String) throws -> Value {
        let type = parameter.variadic ? TypeAnnotation.list(parameter.type) : parameter.type
        guard let conforming = conform(value, to: type) else {
            throw RuntimeError("\(function): '\(parameter.name)' must be \(type), not \(value.typeName)")
        }
        return conforming
    }
}

/// `set` with only the overload the checker chose, when it did.
@_spi(Shell) public func narrowed(_ set: OverloadSet, _ overload: Int?) -> OverloadSet {
    guard let overload, set.candidates.indices.contains(overload) else { return set }
    return OverloadSet(name: set.name, candidates: [set.candidates[overload]])
}

extension Interpreter {
    // MARK: Overloads

    /// Picks the overload that `bind` accepts with the lowest penalty, the
    /// most specific match. Ties are an error, never a guess.
    @_spi(Shell) public func resolve(
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
        let bestMatches = matches.filter { $0.penalty == best }
        guard bestMatches.count == 1 else {
            throw RuntimeError("\(set.name): ambiguous call; these overloads all match:\n"
                + bestMatches.map { "  " + $0.function.signature }.joined(separator: "\n"))
        }
        return (bestMatches[0].function, bestMatches[0].bindings)
    }
}

extension Interpreter {
    /// A plugin's function as the shell's own: the same binding, help and
    /// streaming as a Swish `func`. `plugin` names the module it came from.
    @_spi(Shell) public func hostFunction(_ export: ExportedFunction, plugin: String? = nil) -> Function {
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
            plugin: plugin, isThrowing: export.isThrowing
        )
    }
}

extension TypeAnnotation {
    @_spi(Shell) public init(_ type: SwishType) {
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
