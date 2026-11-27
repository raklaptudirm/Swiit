import Foundation

// Evaluating calls: to functions, methods, initializers and cases.

extension Interpreter {
    /// Calls, members, closures, and what the checker wrote around them.
    func evaluateCallLike(_ expr: Expr) throws -> Value {
        switch expr {
        case .caseLiteral(let name, _):
            throw RuntimeError(
                ".\(name) needs a type here; write the enum's name too, as in Kind.\(name)"
            )
        case .member(.variable("super"), let name):
            return try superProperty(name)
        case .member(let base, let name):
            return try member(name, of: try evaluate(base))
        case .closure(let literal):
            // What the capture list names is taken by it, not by the scope around.
            var used = literal.names
            used.names.subtract(literal.captures.map(\.name))
            var captured = captureScopes(used)
            // `[weak self, n]`: values taken now, which the body sees first.
            if !literal.captures.isEmpty {
                let scope = Scope()
                for capture in literal.captures {
                    var value = try evaluate(capture.value)
                    if capture.isWeak || capture.isUnowned,
                        case .object(let instance as ClassInstance) = value.storage
                    {
                        value = .object(WeakReference(instance))
                    }
                    scope.bindings[capture.name] = Binding(value: value, mutable: false)
                }
                captured.append(scope)
            }
            return .function(
                Function(
                    name: nil,
                    parameters: literal.parameters,
                    returnType: literal.returnType,
                    body: .swiit(literal.body),
                    captured: captured
                )
            )
        case .childTask(let literal):
            let operation = try evaluate(.closure(literal))
            // A task started here is joined before the interpreter goes (`cancelAndJoinTasks`).
            // swiftlint:disable:next unowned_variable_capture
            let handle = try startTask(host: host.makeTaskState()) { [unowned self] in
                try call(operation, with: [])
            }
            return SwiftValue.make(TaskBox(handle), as: "Task")
        case .inoutArgument(let inner):
            return try evaluate(inner)
        case .described(let inner, let type):
            return .string(try describing(try evaluate(inner), type: type))
        case .call(_, let arguments)
        where arguments.contains(where: {
            if case .inoutArgument = $0.value { true } else { false }
        }):
            // `f(&x)`: x goes in, and what f leaves in its `inout` parameter comes back.
            let places = arguments.compactMap { argument -> Expr? in
                if case .inoutArgument(let place) = argument.value { place } else { nil }
            }
            guard case .call(let callee, _) = expr else { preconditionFailure() }
            // The same call, without the marks the places need no more.
            let plain = try evaluateCall(callee, arguments)
            let outputs = task.inoutOutputs
            task.inoutOutputs = []
            for (place, value) in zip(places, outputs) { try assign(place, value) }
            return plain
        case .call(let callee, let arguments):
            return try evaluateCall(callee, arguments)
        case .bridged(let typeName, let member, let receiver, let arguments):
            if let place = expr.subscriptPlace(in: bridged) {
                return try readSubscript(of: place, type: typeName, member: member)
            }
            return try runBridged(typeName, member, receiver: receiver, arguments)
        case .voidValue(let operand):
            _ = try evaluate(operand)
            return Value(record: Value.Record())
        case .specialized(let inner, let types):
            return specialized(try evaluate(inner), types)
        case .chosen(let inner, let overload):
            // A function as a value, with the overload the checker picked.
            if case .function(let set as OverloadSet) = try evaluate(inner).storage {
                return .function(narrowed(set, overload))
            }
            return try evaluate(inner)
        default:
            preconditionFailure("this was sent to the wrong group")
        }
    }

    /// A call: the callee's overload, a struct or enum made, or a function run.
    func evaluateCall(_ callee: Expr, _ arguments: [Argument]) throws -> Value {
        // A generic function whose body names its type parameters: this call's, bound for it.
        if case .specialized = callee {
            return try evaluateCall(.literal(try evaluate(callee)), arguments)
        }

        // The overload the checker chose, when there's a choice.
        var callee = callee
        var overload: Int?
        if case .chosen(let inner, let index) = callee {
            callee = inner
            overload = index
        }

        let value: Value
        if case .optionalMember(let baseExpr, let name) = callee {
            // `x?.f()`: nothing when `x` is nil.
            let base = try evaluate(baseExpr)
            if base == .nothing { return .nothing }
            return try evaluate(.call(.member(.literal(base), name), arguments))
        } else if case .member(let baseExpr, let name) = callee {
            switch try evaluateMemberCall(baseExpr, name, arguments, overload: overload) {
            case .result(let result): return result
            case .callee(let member): value = member
            }
        } else {
            value = try evaluate(callee)
        }

        if let made = try construct(from: value, arguments, overload: overload) {
            return made
        }
        return try invokeValue(value, callee: callee, arguments, overload: overload)
    }

    /// What calling `base.name(…)` came to: the call's result, or, when no method answers, the
    /// member to call as a value.
    private enum MemberCall {
        case result(Value)
        case callee(Value)
    }

    private func evaluateMemberCall(
        _ baseExpr: Expr,
        _ name: String,
        _ arguments: [Argument],
        overload: Int?
    ) throws -> MemberCall {
        // `super.describe()`, `super.init(…)`: above the class whose body this is.
        if case .variable("super") = baseExpr {
            return .result(try callSuperMethod(name, arguments, overload: overload))
        }

        let base = try evaluate(baseExpr)
        if let result = try callOnTypeOrInstance(base, name, arguments, overload: overload) {
            return .result(result)
        }
        if let result = try callOnValue(
            base,
            at: baseExpr,
            name,
            arguments,
            overload: overload
        ) {
            return .result(result)
        }
        return .callee(try member(name, of: base))
    }

    /// A call on a class instance, or on a type: an initializer, a static method, a case.
    private func callOnTypeOrInstance(
        _ base: Value,
        _ name: String,
        _ arguments: [Argument],
        overload: Int?
    ) throws -> Value? {
        // `self.init(…)` in a convenience initializer.
        if name == "init", case .object(let instance as ClassInstance) = base.storage {
            try delegateInitializer(
                of: instance,
                in: task.owners.last ?? instance.type,
                arguments,
                isSuper: false
            )
            return .nothing
        }

        // `obj.move(by: 1)`: the method of the instance's own class, or one it inherits.
        if case .object(let instance as ClassInstance) = base.storage,
            let result = try callClassMethod(instance, name, arguments, overload: overload)
        {
            return result
        }

        // `Counter.make()`: a static or class method, inherited ones too.
        if case .object(let type as ClassType) = base.storage {
            for next in type.chain {
                if let methods = next.members.staticMethods[name] {
                    return try callStatic(narrowed(methods, overload), arguments)
                }
            }
        }

        // `self.init(x: 1)`: another initializer makes the value.
        if name == "init", let record = base.record, let type = structType(of: record) {
            let made = try construct(type, arguments, overload: overload)
            try assign(Assignment(root: "self", path: [], op: nil, value: .literal(made)))
            return .nothing
        }

        // `Level.make()`: a static method of an enum.
        if case .object(let type as Value.EnumCase.Enumeration) = base.storage,
            let methods = enumMembers(of: type)?.staticMethods[name]
        {
            return try callStatic(narrowed(methods, overload), arguments)
        }

        // `P.make()`, `Int.make()`: a static method an extension adds to a type.
        if let typeName = declaredTypeName(of: base),
            let methods = typeExtensions[typeName]?.staticMethods[name]
        {
            return try callStatic(narrowed(methods, overload), arguments)
        }

        // `Result.failed(code: 2)`: a case with associated values.
        if case .object(let type as Value.EnumCase.Enumeration) = base.storage {
            return try makeCase(type, name, arguments)
        }

        // `Point.make(1)`: a static method.
        if case .object(let type as StructType) = base.storage,
            let methods = type.members.staticMethods[name]
        {
            return try callStatic(narrowed(methods, overload), arguments)
        }
        return nil
    }

    /// A method call on a value: an enum's, a struct's, one an extension adds, a sequence's.
    private func callOnValue(
        _ base: Value,
        at baseExpr: Expr,
        _ name: String,
        _ arguments: [Argument],
        overload: Int?
    ) throws -> Value? {
        // `direction.opposite()`: an enum's method, with the case as `self`.
        if case .enumValue(let enumValue) = base.storage,
            let methods = enumMembers(of: enumValue.type)?.methods[name]
        {
            return try callMethod(narrowed(methods, overload), of: base, at: baseExpr, arguments)
        }

        // `p.move(by: 1)`: a struct's method, with `p` as `self`.
        if let record = base.record, record[name] == nil,
            let type = structType(of: record),
            let methods = type.members.methods[name]
        {
            return try callMethod(narrowed(methods, overload), of: base, at: baseExpr, arguments)
        }

        // `x.double()`: a method an extension adds, or a protocol's default, after the type's own.
        if let methods = extensionMethods(name, of: base) {
            return try callMethod(narrowed(methods, overload), of: base, at: baseExpr, arguments)
        }

        // `xs.sorted(by: "size")`: a sequence's method.
        if let methods = sequenceMethods[name], let items = base.sequenceItems {
            return try callSequenceMethod(narrowed(methods, overload), on: items, arguments)
        }
        return nil
    }

    /// `Point(x: 1, y: 2)`, `Dog(name: "Rex")`, `Level(rawValue: 2)`: the value a call makes when
    /// its callee is a type. Nil when the callee is not one.
    private func construct(
        from value: Value,
        _ arguments: [Argument],
        overload: Int?
    ) throws
        -> Value?
    {
        switch value.storage {
        case .object(let type as StructType):
            return try construct(type, arguments, overload: overload)

        case .object(let type as ClassType):
            return try construct(type, arguments, overload: overload)

        case .object(let type as Value.EnumCase.Enumeration):
            // The case with that raw value, or nil.
            if !(arguments.count == 1 && arguments[0].label == "rawValue"),
                let initializers = enumMembers(of: type)?.initializers
            {
                return try constructEnum(type, initializers, arguments, overload: overload)
            }
            guard arguments.count == 1, arguments[0].label == "rawValue" else {
                throw RuntimeError(
                    "\(type.name) is made from a raw value: \(type.name)(rawValue: …)"
                )
            }
            return type.case(rawValue: try evaluate(arguments[0].value)).map(Value.enumValue)
                ?? .nothing

        case .object(let type as NativeTypeName):
            return try constructBridged(type, arguments)

        default:
            return nil
        }
    }

    /// A call to a function value: a function, an overload set or a key path.
    private func invokeValue(
        _ value: Value,
        callee: Expr,
        _ arguments: [Argument],
        overload: Int?
    ) throws -> Value {
        // A function's type has no argument labels: called through a variable, a function takes
        // its arguments in order, whatever it was declared with.
        var arguments = arguments
        if !isDeclaredFunctionName(callee) { arguments = unlabeled(arguments, for: value) }
        if let result = try callPlainly(value, arguments) { return result }

        // `.case` arguments wait for their parameter's type.
        let values = try evaluatedArguments(arguments)
        switch value.storage {
        case .function(let set as OverloadSet):
            let (function, bindings) = try resolve(narrowed(set, overload)) {
                try self.bind(values, to: $0)
            }
            return try invoke(function, with: bindings)

        case .function(let function as Function):
            return try invoke(function, with: try bind(values, to: function).bindings)

        case .function(let keyPath as KeyPathValue):
            guard values.count == 1 else { throw RuntimeError("a key path reads one value") }
            return try keyPath.read(from: try evaluate(values[0].value), in: self)

        default:
            throw RuntimeError("\(value.typeName) isn't a function")
        }
    }

    /// The arguments of a call, evaluated, except a `.case` literal, which waits for the type of
    /// its parameter.
    private func evaluatedArguments(_ arguments: [Argument]) throws -> [Argument] {
        try arguments.map { argument in
            if case .caseLiteral = argument.value { return argument }
            return Argument(label: argument.label, value: .literal(try evaluate(argument.value)))
        }
    }

    /// `String(n)` in a body nothing has checked (a type a host declared): the checker chooses the
    /// initializer, for the values the call is given.
    private func constructBridged(_ type: NativeTypeName, _ arguments: [Argument]) throws -> Value {
        let given = try evaluatedArguments(arguments)
        var call = Expr.call(.variable(type.name), given)
        do { _ = try TypeChecker(interpreter: self).typeOf(&call) } catch let error as TypeError {
            throw RuntimeError(error.message)
        }
        return try evaluate(call)
    }

    /// Whether a call's callee names a function declared with `func` (or a host's), whose labels the
    /// call must write, rather than a value of function type.
    private func isDeclaredFunctionName(_ callee: Expr) -> Bool {
        switch callee {
        case .variable(let name): return lookup(name)?.isFunction ?? false
        // A local is a value, never a declared function.
        case .local: return false
        case .literal(let value): return !value.isFunction
        default: return true
        }
    }

    /// The arguments given the labels of the function's parameters, in order: how a call through a
    /// value of function type is read. Only one function with that many parameters can be meant, so
    /// an overloaded set that is ambiguous by count is left as written.
    func unlabeled(_ arguments: [Argument], for value: Value) -> [Argument] {
        guard case .function(let target) = value.storage else { return arguments }
        let function: Function
        if let only = target as? Function {
            function = only
        } else if let set = target as? OverloadSet, set.candidates.count == 1 {
            function = set.candidates[0]
        } else {
            return arguments
        }
        guard function.parameters.count == arguments.count,
            !function.parameters.contains(where: \.variadic)
        else { return arguments }
        return zip(arguments, function.parameters)
            .map {
                Argument(label: $1.label, value: $0.value)
            }
    }

    /// A call to the one function there is, with each argument for the parameter in its place: no
    /// overload to choose and nothing to match, so the arguments become its scope directly. Nil for
    /// any other call.
    private func callPlainly(_ value: Value, _ arguments: [Argument]) throws -> Value? {
        guard case .function(let target) = value.storage else { return nil }
        let only =
            (target as? OverloadSet).flatMap { $0.candidates.count == 1 ? $0.candidates[0] : nil }
            ?? (target as? Function)
        guard let only, let table = try bindPlainly(arguments, to: only) else { return nil }
        defer { task.lastCallee = only }
        let maxCallDepth = task.run.limits.maxCallDepth
        guard callDepth < maxCallDepth else {
            throw RuntimeError("maximum call depth (\(maxCallDepth)) exceeded")
        }
        try checkInterrupt()
        return try runSwiit(only, with: table)
    }

    static func isCaseLiteral(_ expr: Expr) -> Bool {
        if case .caseLiteral = expr { true } else { false }
    }
}
