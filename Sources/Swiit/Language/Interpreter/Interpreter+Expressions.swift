import Foundation

extension Interpreter {
    // MARK: Expressions

    func evaluate(_ expr: Expr) throws -> Value {
        switch expr {
        case .literal, .string, .variable, .filePath, .keyPath, .ifExpression:
            return try evaluateName(expr)
        case .list, .record, .tuple:
            return try evaluateCollection(expr)
        case .forceUnwrap, .optionalMember, .optionalIndex, .attempt, .await:
            return try evaluateOptional(expr)
        case .caseLiteral, .member, .call, .bridged, .closure, .childTask, .inoutArgument, .described, .voidValue, .specialized, .chosen:
            return try evaluateCallLike(expr)
        case .annotated, .unary, .binary, .index, .subscripted, .indexDefault, .cast:
            return try evaluateOperation(expr)
        }
    }

    /// Literals and names.
    private func evaluateName(_ expr: Expr) throws -> Value {
        switch expr {
        case .literal(let value):
            return value
        case .string(let parts):
            return .string(try expand(parts))
        case .variable(let name):
            guard let binding = lookup(name) else { throw RuntimeError("no variable named '\(name)'") }
            // A weak variable gives what it refers to, or nil once that is gone.
            let value = binding.value
            if case .object(let reference as WeakReference) = value { return reference.target.map { .object($0) } ?? .nothing }
            return value
        case .filePath:
            return .string(file ?? "<prompt>")
        case .ifExpression(let node):
            let (branch, bindings) = try chooseBranch(node)
            guard let branch, let expr = IfStatement.branchExpression(branch) else { return .nothing }
            scopes.append(Scope(bindings))
            defer { scopes.removeLast() }
            return try evaluate(expr)
        case .keyPath(_, let path):
            return .function(KeyPathValue(path: path))
        default:
            preconditionFailure("this was sent to the wrong group")
        }
    }

    /// Lists, records and tuples.
    private func evaluateCollection(_ expr: Expr) throws -> Value {
        switch expr {
        case .list(let elements):
            return .list(try elements.map(evaluate))
        case .record(let entries):
            // `["a": 1]`: a dictionary, as in Swift.
            var dictionary = ValueDictionary()
            for entry in entries {
                dictionary[try evaluate(entry.key)] = try evaluate(entry.value)
            }
            return .dictionary(dictionary)
        case .tuple(let elements):
            // `(name: "x", 2)`: unlabeled elements are keyed by position.
            var record = Record()
            for (index, element) in elements.enumerated() {
                record[element.label ?? String(index)] = try evaluate(element.value)
            }
            return .record(record)
        default:
            preconditionFailure("this was sent to the wrong group")
        }
    }

    /// Optionals, `try`, and `await`.
    private func evaluateOptional(_ expr: Expr) throws -> Value {
        switch expr {
        case .forceUnwrap(let inner):
            let value = try evaluate(inner)
            guard value != .nothing else {
                throw RuntimeError("\(SwiftPrinter().source(inner)) is nil, but '!' needs a value")
            }
            return value
        case .optionalMember(let base, let name):
            let value = try evaluate(base)
            return value == .nothing ? .nothing : try member(name, of: value)
        case .optionalIndex(let base, let index):
            let value = try evaluate(base)
            return value == .nothing ? .nothing : try element(of: value, at: try evaluate(index))
        case .attempt(let operand, .plain):
            return try evaluate(operand)
        case .attempt(let operand, .optional):
            do {
                return try evaluate(operand)
            } catch is RuntimeError {
                return .nothing
            } catch is AlreadyReported {
                return .nothing
            }
        case .attempt(let operand, .forced):
            do {
                return try evaluate(operand)
            } catch let error as RuntimeError {
                throw FatalError(error: error)
            }
        case .await(let target, let throwing):
            let value = try target.map { try evaluate($0) }
            // `await f()`: what the call gave. (The interpreter waits at every wait anyway.)
            if let value, awaiting?.isHandle(value) != true { return value }
            guard let awaiting else { throw RuntimeError("there is nothing to await here") }
            return try awaiting.perform(value, throwing)
        default:
            preconditionFailure("this was sent to the wrong group")
        }
    }

    /// Calls, members, closures, and what the checker wrote around them.
    private func evaluateCallLike(_ expr: Expr) throws -> Value {
        switch expr {
        case .caseLiteral(let name, _):
            throw RuntimeError(".\(name) needs a type here; write the enum's name too, as in Kind.\(name)")
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
                    if capture.isWeak || capture.isUnowned, case .object(let instance as ClassInstance) = value { value = .object(WeakReference(instance)) }
                    scope.bindings[capture.name] = Binding(value: value, mutable: false)
                }
                captured.append(scope)
            }
            return .function(Function(
                name: nil, parameters: literal.parameters, returnType: literal.returnType,
                body: .swiit(literal.body), captured: captured
            ))
        case .childTask(let literal):
            let operation = try evaluate(.closure(literal))
            let handle = try startTask(host: newTaskHost?()) { [unowned self] in try call(operation, with: []) }
            return SwiftValue.make(TaskBox(handle), as: "Task")
        case .inoutArgument(let inner):
            return try evaluate(inner)
        case .described(let inner, let type):
            return .string(try describing(try evaluate(inner), type: type))
        case .call(_, let arguments) where arguments.contains(where: { if case .inoutArgument = $0.value { true } else { false } }):
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
            return try runBridged(typeName, member, receiver: receiver, arguments)
        case .voidValue(let operand):
            _ = try evaluate(operand)
            return .record(Record())
        case .specialized(let inner, let types):
            return specialized(try evaluate(inner), types)
        case .chosen(let inner, let overload):
            // A function as a value, with the overload the checker picked.
            if case .function(let set as OverloadSet) = try evaluate(inner) {
                return .function(narrowed(set, overload))
            }
            return try evaluate(inner)
        default:
            preconditionFailure("this was sent to the wrong group")
        }
    }

    /// Operators, indexing and casts.
    private func evaluateOperation(_ expr: Expr) throws -> Value {
        switch expr {
        case .annotated(let inner, let type):
            let value = try evaluate(inner, expecting: type)
            guard let conforming = conform(value, to: type) else {
                throw RuntimeError("expected \(type), not \(value.typeName)")
            }
            return conforming
        case .binary(let op, let lhs, let rhs):
            return try evaluateBinary(op, lhs, rhs)
        case .unary(let op, let operand):
            return try apply(op, try evaluate(operand))
        case .cast(let inner, let type, let kind):
            let value = try evaluate(inner)
            let converted = conform(value, to: type)
            switch kind {
            case .conditional: return converted ?? .nothing
            case .check: return .bool(converted != nil)
            case .upcast: return converted ?? value
            case .forced:
                guard let converted else { throw RuntimeError("'as!' failed: a \(value.typeName) isn't a \(type)") }
                return converted
            }
        case .index(let base, let index):
            let value = try evaluate(base)
            if case .record(let record) = value, let type = structType(of: record), !type.subscriptGetters.isEmpty {
                return try readSubscript(record, type, [Argument(value: index)])
            }
            if case .object(let instance as ClassInstance) = value { return try readSubscript(instance, [Argument(value: index)]) }
            return try element(of: value, at: try evaluate(index))
        case .subscripted(let base, let arguments):
            let target = try evaluate(base)
            if case .object(let instance as ClassInstance) = target { return try readSubscript(instance, arguments) }
            guard case .record(let record) = target, let type = structType(of: record), !type.subscriptGetters.isEmpty else {
                throw RuntimeError("this value has no subscript")
            }
            return try readSubscript(record, type, arguments)
        case .indexDefault(let base, let key, let fallback):
            guard case .dictionary(let dictionary) = try evaluate(base) else { throw RuntimeError("'default:' goes with a dictionary") }
            return try dictionary[try evaluate(key)] ?? evaluate(fallback)
        default:
            preconditionFailure("this was sent to the wrong group")
        }
    }

    /// `lhs op rhs`: a few operators look at their operands first (`&&`, `??`, a `.case` on one side); the rest evaluate both and apply.
    private func evaluateBinary(_ op: BinaryOperator, _ lhs: Expr, _ rhs: Expr) throws -> Value {
        switch op {
        case .and:
            return .bool(try truth(lhs, for: .and) && truth(rhs, for: .and))
        case .or:
            return .bool(try truth(lhs, for: .or) || truth(rhs, for: .or))
        case .coalesce:
            let value = try evaluate(lhs)
            if value == .nothing { return try evaluate(rhs) }
            // `(try? $(git config x)) ?? "vi"` is a String: the checker types
            // it so, so the Output gives its text.
            if case .object = value, let text = value.text, rhs.isStringExpression { return .string(text) }
            return value
        case .closedRange, .halfOpenRange:
            return try makeRange(op, try evaluate(lhs), try evaluate(rhs))
        case .equal, .notEqual:
            if Interpreter.isCaseLiteral(lhs) || Interpreter.isCaseLiteral(rhs) {
                // `$0.type == .directory`: the case comes from the other side's enum.
                let known = try evaluate(Interpreter.isCaseLiteral(lhs) ? rhs : lhs)
                guard case .enumValue(let enumValue) = known else {
                    throw RuntimeError("\(op.rawValue) with a .case needs an enum on the other side, not \(known.typeName)")
                }
                let literal = Interpreter.isCaseLiteral(lhs) ? lhs : rhs
                guard case .caseLiteral(let name, let arguments) = literal else { preconditionFailure() }
                let equal = try makeCase(enumValue.type, name, arguments) == known
                return .bool(op == .equal ? equal : !equal)
            }
        case .less, .lessEqual, .greater, .greaterEqual:
            if Interpreter.isCaseLiteral(lhs) || Interpreter.isCaseLiteral(rhs) {
                // `level < .high`: the case comes from the other side's enum.
                let known = try evaluate(Interpreter.isCaseLiteral(lhs) ? rhs : lhs)
                guard case .enumValue(let enumValue) = known else {
                    throw RuntimeError("\(op.rawValue) with a .case needs an enum on the other side, not \(known.typeName)")
                }
                guard case .caseLiteral(let name, let arguments) = Interpreter.isCaseLiteral(lhs) ? lhs : rhs else { preconditionFailure() }
                let literal = try makeCase(enumValue.type, name, arguments)
                return Interpreter.isCaseLiteral(lhs) ? try apply(op, literal, known) : try apply(op, known, literal)
            }
        default:
            break
        }
        return try apply(op, try evaluate(lhs), try evaluate(rhs))
    }

    /// A call: the callee's overload, a struct or enum made, or a function run.
    func evaluateCall(_ callee: Expr, _ arguments: [Argument]) throws -> Value {
        // A generic function whose body names its type parameters: this call's, bound for it.
        if case .specialized = callee { return try evaluateCall(.literal(try evaluate(callee)), arguments) }
        // The overload the checker chose, when there's a choice.
        var callee = callee
        var overload: Int?
        if case .chosen(let inner, let index) = callee {
            callee = inner
            overload = index
        }
        let value: Value
        // `x?.f()`: nothing when `x` is nil.
        if case .optionalMember(let baseExpr, let name) = callee {
            let base = try evaluate(baseExpr)
            if base == .nothing { return .nothing }
            return try evaluate(.call(.member(.literal(base), name), arguments))
        }
        if case .member(let baseExpr, let name) = callee {
            // `super.describe()`, `super.init(…)`: above the class whose body this is.
            if case .variable("super") = baseExpr { return try callSuperMethod(name, arguments, overload: overload) }
            let base = try evaluate(baseExpr)
            // `self.init(…)` in a convenience initializer.
            if name == "init", case .object(let instance as ClassInstance) = base {
                try delegateInitializer(of: instance, in: task.owners.last ?? instance.type, arguments, isSuper: false)
                return .nothing
            }
            // `obj.move(by: 1)`: the method of the instance's own class, or one it inherits.
            if case .object(let instance as ClassInstance) = base, let result = try callClassMethod(instance, name, arguments, overload: overload) {
                return result
            }
            // `Counter.make()`: a static or class method, inherited ones too.
            if case .object(let type as ClassType) = base {
                for next in type.chain {
                    if let methods = next.staticMethods[name] { return try callStatic(narrowed(OverloadSet(name: name, candidates: methods), overload), arguments) }
                }
            }
            // `self.init(x: 1)`: another initializer makes the value.
            if name == "init", case .record(let record) = base, let type = structType(of: record) {
                let made = try construct(type, arguments, overload: overload)
                try assign(Assignment(root: "self", path: [], op: nil, value: .literal(made)))
                return .nothing
            }
            // `Level.make()`: a static method of an enum.
            if case .object(let type as EnumType) = base, let methods = enumMembers[ObjectIdentifier(type)]?.staticMethods[name] {
                return try callStatic(narrowed(methods, overload), arguments)
            }
            // `P.make()`: a static method an extension adds to a struct or enum.
            if case .object(let type as StructType) = base, let methods = typeExtensions[type.name]?.staticMethods[name] {
                return try callStatic(narrowed(methods, overload), arguments)
            }
            if case .object(let type as EnumType) = base, let methods = typeExtensions[type.name]?.staticMethods[name] {
                return try callStatic(narrowed(methods, overload), arguments)
            }
            // `Result.failed(code: 2)`: a case with associated values.
            if case .object(let type as EnumType) = base {
                return try makeCase(type, name, arguments)
            }
            // `direction.opposite()`: an enum's method, with the case as `self`.
            if case .enumValue(let enumValue) = base, let methods = enumMembers[ObjectIdentifier(enumValue.type)]?.methods[name] {
                return try callMethod(narrowed(methods, overload), of: base, at: baseExpr, arguments)
            }
            // `Point.make(1)`: a static method.
            if case .object(let type as StructType) = base, let methods = type.staticMethods[name] {
                return try callStatic(narrowed(methods, overload), arguments)
            }
            // `p.move(by: 1)`: a struct's method, with `p` as `self`.
            if case .record(let record) = base, record[name] == nil, let type = structType(of: record),
               let methods = type.methods[name] {
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
            value = try member(name, of: base)
        } else {
            value = try evaluate(callee)
        }
        // `Point(x: 1, y: 2)`: a new struct.
        if case .object(let type as StructType) = value {
            return try construct(type, arguments, overload: overload)
        }
        // `Dog(name: "Rex")`: a new instance.
        if case .object(let type as ClassType) = value {
            return try construct(type, arguments, overload: overload)
        }
        // `Level(rawValue: 2)`: the case with that raw value, or nil.
        if case .object(let type as EnumType) = value {
            if !(arguments.count == 1 && arguments[0].label == "rawValue"), let initializers = enumMembers[ObjectIdentifier(type)]?.initializers {
                return try constructEnum(type, initializers, arguments, overload: overload)
            }
            guard arguments.count == 1, arguments[0].label == "rawValue" else {
                throw RuntimeError("\(type.name) is made from a raw value: \(type.name)(rawValue: …)")
            }
            return type.case(rawValue: try evaluate(arguments[0].value)).map(Value.enumValue) ?? .nothing
        }
        if let result = try callPlainly(value, arguments) { return result }
        // `.case` arguments wait for their parameter's type.
        let values = try arguments.map { argument -> Argument in
            if case .caseLiteral = argument.value { return argument }
            return Argument(label: argument.label, value: .literal(try evaluate(argument.value)))
        }
        switch value {
        case .function(let set as OverloadSet):
            let (function, bindings) = try resolve(narrowed(set, overload)) { try self.bind(values, to: $0) }
            return try invoke(function, with: bindings)
        case .function(let function as Function):
            return try invoke(function, with: try bind(values, to: function).bindings)
        case .function(let native as NativeFunction):
            let function = hostFunction(native.function)
            return try invoke(function, with: try bind(values, to: function).bindings)
        case .function(let keyPath as KeyPathValue):
            guard values.count == 1 else { throw RuntimeError("a key path reads one value") }
            return try keyPath.read(from: try evaluate(values[0].value), in: self)
        default:
            throw RuntimeError("\(value.typeName) isn't a function")
        }
    }

    /// A call to the one function there is, with each argument for the parameter in its place: no overload to choose and
    /// nothing to match, so the arguments become its scope directly. Nil for any other call.
    private func callPlainly(_ value: Value, _ arguments: [Argument]) throws -> Value? {
        guard case .function(let target) = value else { return nil }
        let only = (target as? OverloadSet).flatMap { $0.candidates.count == 1 ? $0.candidates[0] : nil } ?? (target as? Function)
        guard let only, let scope = try bindPlainly(arguments, to: only) else { return nil }
        guard callDepth < limits.depth else { throw RuntimeError("maximum call depth (\(limits.depth)) exceeded") }
        try checkInterrupt()
        return try runSwiit(only, in: scope)
    }

    static func isCaseLiteral(_ expr: Expr) -> Bool {
        if case .caseLiteral = expr { true } else { false }
    }

    /// Record fields first, then the few members values have.
    @_spi(Layer) public func member(_ name: String, of value: Value) throws -> Value {
        if case .enumValue(let enumValue) = value, name == "rawValue" {
            guard let raw = enumValue.rawValue else { throw RuntimeError("\(enumValue.type.name) has no raw values") }
            return raw
        }
        if case .enumValue(let enumValue) = value, let found = try enumMember(name, of: enumValue) { return found }
        if case .object(let instance as ClassInstance) = value, let found = try classMember(name, of: instance) { return found }
        if case .object(let type as ClassType) = value, let found = try classStaticMember(name, of: type) { return found }
        // A struct's own members come before what extensions add.
        if case .record = value {} else if let found = try extensionMember(name, of: value) { return found }
        if case .object(let type as StructType) = value, let found = try extensionStaticMember(name, ofTypeNamed: type.name) { return found }
        if case .object(let type as EnumType) = value, let found = try extensionStaticMember(name, ofTypeNamed: type.name) { return found }
        if case .object(let type as EnumType) = value, let found = try enumStaticMember(name, of: type) { return found }
        if case .object(let type as EnumType) = value, type.case(named: name) != nil, type.member(name) == nil {
            return try makeCase(type, name, nil) // Says what values it needs.
        }
        if case .object(let type as StructType) = value, let found = try staticMember(name, of: type) { return found }
        // An unset environment variable is nil, not a missing field.
        if case .object(let object as DynamicObject) = value { return try object.read(name) }
        if case .object(let object) = value, name != "description" && name != "debugDescription" {
            if object is SwiftValue, let property = try bridgedProperty(name, of: value) { return property }
            if object is SwiftValue, let method = bridgedMethods(name, of: value) { return method }
            guard let member = object.member(name) else {
                throw RuntimeError("\(object.typeName) has no member '\(name)'")
            }
            return member
        }
        // Every value has its textual form, as a CustomStringConvertible
        // does in Swift: what interpolation shows. A record's own field of
        // that name comes first.
        if name == "description" || name == "debugDescription" {
            if case .record(let record) = value, let field = record[name] { return field }
            return .string(name == "description" ? value.description : value.debugDescription)
        }
        // What every Error says of itself, unless its type says otherwise: its
        // value, as Swift's describes an error it has no message for.
        if name == "localizedDescription", isError(value) {
            if case .record(let record) = value, let field = record[name] { return field }
            if case .record(let record) = value, let type = structType(of: record),
               let found = try structMember(name, of: record, type) { return found }
            return .string(value.description)
        }
        // `pair.1`: a tuple's element by position, labeled or not.
        if case .record(let record) = value, record.typeName == nil, record[name] == nil,
           let position = Int(name), position >= 0, position < record.count {
            return Array(record)[position].value
        }
        if case .record(let record) = value, record[name] == nil, let type = structType(of: record),
           let found = try structMember(name, of: record, type) {
            return found
        }
        if case .record = value, let found = try extensionMember(name, of: value) { return found }
        // Swiit's own kinds, and its views of Swift's, as the checker's
        // `memberType(of:_:)` types them.
        switch (value, name) {
        case (.record(let record), _) where record[name] != nil: return record[name]!
        case (.record(let record), "count"): return .int(record.count)
        case (.record(let record), "isEmpty"): return .bool(record.isEmpty)
        case (.record(let record), "keys"): return .list(record.keys.map(Value.string))
        case (.record(let record), "values"): return .list(record.map(\.value))
        case (.dictionary(let dictionary), "keys"): return .list(dictionary.keys)
        case (.dictionary(let dictionary), "values"): return .list(dictionary.values)
        case (.string(let text), "lines"):
            return .list(text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).map { .string(String($0)) })
        case (.record(let record), _):
            throw RuntimeError("\(record.typeName ?? "Record") has no field '\(name)'")
        default:
            // Swift's own properties, as a key path like `\.count` reads them.
            if let property = try bridgedProperty(name, of: value) { return property }
            if let method = bridgedMethods(name, of: value) { return method }
            throw RuntimeError("\(value.typeName) has no member '\(name)'")
        }
    }

    func element(of base: Value, at index: Value) throws -> Value {
        if case .string(let text) = base { return try Bridge.subscriptString(text, index) }
        if case .object(let object as DynamicObject) = base {
            guard case .string(let name) = index else {
                throw RuntimeError("\(object.typeName) is indexed by name, not \(index.typeName)")
            }
            return try object.read(name)
        }
        if case .dictionary(let dictionary) = base {
            return dictionary[index] ?? .nothing
        }
        if case .record(let record) = base, case .string(let key) = index {
            return record[key] ?? .nothing
        }
        // A Swift sequence Swiit holds is indexed by position (a command's output, by line); subscripts aren't bridged yet.
        if case .object = base, let items = Interpreter.items(of: base) {
            return try element(of: .list(Array(items)), at: index)
        }
        guard case .list(let elements) = base else {
            throw RuntimeError("\(base.typeName) can't be indexed")
        }
        // `xs[1...3]`: a slice, as Swift's ArraySlice.
        if case .object(let box as SwiftValue) = index {
            var bounds: Range<Int>?
            if let range = box.value as? ClosedRange<Value>, case .int(let low) = range.lowerBound, case .int(let high) = range.upperBound, high < Int.max {
                bounds = low..<(high + 1)
            } else if let range = box.value as? Range<Value>, case .int(let low) = range.lowerBound, case .int(let high) = range.upperBound {
                bounds = low..<high
            }
            if let bounds {
                guard bounds.lowerBound >= 0, bounds.upperBound <= elements.count else {
                    throw RuntimeError("range \(bounds.lowerBound)..<\(bounds.upperBound) is out of range for a list of \(elements.count)")
                }
                return SwiftValue.make(ArraySlice(elements[bounds]), as: "ArraySlice")
            }
        }
        guard case .int(let i) = index else {
            throw RuntimeError("a list index must be an Int, not \(index.typeName)")
        }
        guard elements.indices.contains(i) else {
            throw RuntimeError("index \(i) is out of range for a list of \(elements.count)")
        }
        return elements[i]
    }
}

extension Interpreter {
    static let typeArgumentPrefix = InternalName.typeArgumentPrefix

    /// A generic function with its type parameters bound to the types of one call, as values the body can name.
    func specialized(_ function: Value, _ types: [TypeArgument]) -> Value {
        var bindings: [String: Binding] = [:]
        for type in types {
            if let object = typeValue(of: type.type) {
                bindings[type.name] = Binding(value: object, mutable: false)
                // Kept under a name no program writes, for a test against it (`x as? T`), which a global type of the same name mustn't answer.
                bindings[Interpreter.typeArgumentPrefix + type.name] = Binding(value: object, mutable: false)
            }
        }
        guard !bindings.isEmpty, case .function(let callable) = function else { return function }
        let scope = Scope(bindings)
        if let set = callable as? OverloadSet {
            return .function(OverloadSet(name: set.name, candidates: set.candidates.map { $0.typeParameters.isEmpty ? $0 : $0.capturing(scope) }))
        }
        if let single = callable as? Function, !single.typeParameters.isEmpty { return .function(single.capturing(scope)) }
        return function
    }

    /// The value that stands for a type (`Int.self`), if one does: a type parameter's is whatever it is bound to here.
    func typeValue(of annotation: TypeAnnotation) -> Value? {
        let name: String
        switch annotation {
        case .int: name = "Int"
        case .double: name = "Double"
        case .string: name = "String"
        case .bool: name = "Bool"
        case .named(let named): name = named
        case .generic(let named, _): name = named
        case .list: name = "Array"
        case .dictionary: name = "Dictionary"
        case .parameter(let parameter): return lookup(parameter)?.value
        default: return nil
        }
        return lookup(name)?.value
    }

    /// The annotation a type value stands for, to test a value against.
    func annotation(ofTypeValue value: Value) -> TypeAnnotation? {
        guard case .object(let object) = value else { return nil }
        let name: String
        switch object {
        case let type as ClassType: name = type.name
        case let type as StructType: name = type.name
        case let type as EnumType: name = type.name
        case let type as ProtocolType: name = type.name
        case let type as BridgedTypeName: name = type.name
        default: return nil
        }
        return TypeAnnotation.spelled(name) ?? .named(name)
    }
}
