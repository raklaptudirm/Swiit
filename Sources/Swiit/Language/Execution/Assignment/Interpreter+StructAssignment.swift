import Foundation

// Assigning into a struct's properties and subscripts, in place or as a copy.

extension Interpreter {
    /// `p`, `p.a`, `xs[0].b`: somewhere a value can be put back.
    func lvalue(_ expr: Expr) -> (String, [Assignment.Step])? {
        switch expr {
        case .variable(let name):
            return (name, [])
        case .local(let local):
            return (local.name, [])
        case .member(let base, let name):
            return lvalue(base).map { ($0.0, $0.1 + [.member(name)]) }
        case .index(let base, let index):
            return lvalue(base).map { ($0.0, $0.1 + [.index(index)]) }
        case .indexDefault(let base, let key, let fallback):
            return lvalue(base).map { ($0.0, $0.1 + [.indexDefault(key, fallback)]) }
        case .forceUnwrap(let base):
            return lvalue(base).map { ($0.0, $0.1 + [.unwrap]) }
        default:
            return nil
        }
    }

    /// Puts what a mutating method made of `receiver` back where it came
    /// from: a variable, or a part of one.
    func mutate(_ receiver: Expr, by method: String, _ change: (Value) throws -> Value) throws {
        guard let (root, path) = lvalue(receiver) else {
            throw RuntimeError(
                "cannot use mutating method '\(method)' on a value that isn't in a variable"
            )
        }
        try checkAssignable(root, what: "use mutating method '\(method)' on")
        try update(root, path) { current, _ in try change(current) }
    }

    /// `x = v`, `p.x += 1`, `xs[0] = v`, `r["k"] = v`.
    func assign(_ assignment: Assignment) throws {
        // `Point.count += 1`: a static var, set through its type. A change inside an instance is to
        // the instance itself, which the variable holding it needn't allow.
        var holdsInstance = false
        if !assignment.path.isEmpty {
            switch lookup(assignment.root)?.value.storage {
            case .object(is ClassInstance)?, .object(is ClassType)?: holdsInstance = true
            default: break
            }
        }
        if structType(named: assignment.root) == nil,
            !holdsInstance
        {
            try checkAssignable(assignment.root, what: "assign to")
        }
        // Where it can be, the change is made where the value is, not on a copy of it (see
        // Interpreter+InPlace.swift).
        if let place = try plainPlace(assignment.root, assignment.path, op: assignment.op) {
            var value = try evaluate(assignment.value, expecting: place.type)
            // A property's type is checked for what is put in it; a collection changed in it keeps
            // its type, and isn't walked again.
            if assignment.op == nil, let validate = place.validate { value = try validate(value) }
            try withPlace(assignment.root, place) { slot in
                guard let op = assignment.op else { slot = value; return }
                try applyInPlace(op, &slot, value)
                switch slot.storage {
                case .int, .double, .bool:
                    if let validate = place.validate { slot = try validate(slot) }
                default: break
                }
            }
            return
        }
        task.assigningPlainly = assignment.op == nil
        defer { task.assigningPlainly = false }
        try update(assignment.root, assignment.path) { current, type in
            let value = try evaluate(assignment.value, expecting: type)
            // A weak variable stays weak: what is put in it is held without being kept alive.
            if assignment.path.isEmpty, case .object(is WeakReference) = current.storage,
                assignment.op == nil
            {
                if case .object(let instance as ClassInstance) = value.storage {
                    return .object(WeakReference(instance))
                }
                if value == .nothing { return .object(WeakReference(nil)) }
            }
            guard let op = assignment.op else { return value }
            // `a += b` through a `+=` the type defines, whose first parameter is `inout`.
            if isDeclaredValue(current), !staticOperators("\(op.rawValue)=", of: current).isEmpty {
                task.inoutOutputs = []
                _ = try userOperator("\(op.rawValue)=", [current, value])
                let outputs = task.inoutOutputs
                task.inoutOutputs = []
                if let changed = outputs.first { return changed }
            }
            return try apply(op, current, value)
        }
    }

    /// Puts `value` where a place (`x`, `p.a`, `xs[0]`) is, as an assignment would.
    func assign(_ place: Expr, _ value: Value) throws {
        var path: [Assignment.Step] = []
        var current = place
        while true {
            switch current {
            case .member(let inner, let name):
                path.insert(.member(name), at: 0)
                current = inner
            case .index(let inner, let index):
                path.insert(.index(index), at: 0)
                current = inner
            case .forceUnwrap(let inner):
                path.insert(.unwrap, at: 0)
                current = inner
            case .variable(let root):
                try assign(Assignment(root: root, path: path, op: nil, value: .literal(value)))
                return
            case .local(let local):
                try assign(
                    Assignment(root: local.name, path: path, op: nil, value: .literal(value))
                )
                return
            default:
                throw RuntimeError("only a variable can be passed with &")
            }
        }
    }

    func checkAssignable(_ root: String, what: String) throws {
        guard let binding = lookup(root) else { throw RuntimeError("no variable named '\(root)'") }
        guard binding.mutable else {
            if root == "self" {
                throw RuntimeError(
                    "cannot \(what) self here: it's only changed by a mutating method"
                )
            }
            throw RuntimeError("cannot \(what) '\(root)': it's a 'let' constant")
        }
    }

    /// Replaces the value at `path` in the variable `root` with what
    /// `change` makes of it (given the current value and the type the
    /// place holds, if known).
    func update(
        _ root: String,
        _ path: [Assignment.Step],
        _ change: (Value, TypeAnnotation?) throws -> Value
    ) throws {
        guard let binding = lookup(root) else {
            throw RuntimeError("no variable named '\(root)'")
        }
        let current = binding.value
        let initializing = binding.special == .initializing
        binding.value = try updated(
            current,
            path[...],
            type: nil,
            initializing: initializing,
            change
        )
    }

    // swiftlint:disable cyclomatic_complexity function_body_length - one branch for each case; a long walk over every case; splitting it is item 17 of Docs/agenda.md
    /// `initializing`: this is `self` in an `init`, whose own `let`
    /// properties can be set.
    func updated(
        _ base: Value,
        _ path: ArraySlice<Assignment.Step>,
        type: TypeAnnotation?,
        initializing: Bool = false,
        _ change: (Value, TypeAnnotation?) throws -> Value
    ) throws -> Value {
        guard let step = path.first else { return try change(base, type) }
        let rest = path.dropFirst()
        switch (step, base.storage) {
        case (.optionalChain, _):
            // Nothing is nil's to change, and what would have been assigned isn't worked out.
            guard base != .nothing else { return base }
            return try updated(base, rest, type: type, initializing: initializing, change)
        case (.unwrap, _):
            guard base != .nothing else { throw RuntimeError("nil was unwrapped with '!'") }
            return try updated(base, rest, type: type, initializing: initializing, change)
        case (.member(let name), _) where base.record != nil:
            var record = base.record!
            if let structType = structType(of: record) {
                // A computed property with a setter: the new value goes through it.
                if let setter = structType.setters[name]
                    ?? extensionChain(of: base).lazy.compactMap({ $0.setters[name] }).first
                {
                    // `x.0 = 1` through a computed `x`: its value is read, changed inside, and set
                    // back.
                    let current =
                        task.assigningPlainly && rest.isEmpty
                        ? Value.nothing : try structMember(name, of: record, structType) ?? .nothing
                    let receiver = Receiver(Value(record: record), mutable: true)
                    let returnType = structType.computed[name]?.returnType
                    let newValue =
                        try rest.isEmpty
                        ? change(current, returnType)
                        : updated(current, rest, type: returnType, change)
                    let parameter = setter.parameters[0]
                    _ = try invoke(
                        setter,
                        with: [parameter.name: try checked(newValue, for: parameter, of: name)],
                        receiver: receiver
                    )
                    return receiver.value
                }
                guard let property = structType.property(name) else {
                    let what =
                        structType.computed[name] != nil
                        ? "it's a computed property"
                        : "\(structType.name) has no property '\(name)'"
                    throw RuntimeError("cannot assign to '\(name)': \(what)")
                }
                guard property.mutable || (initializing && path.count == 1) else {
                    throw RuntimeError(
                        "cannot assign to '\(name)': it's a 'let' property of \(structType.name)"
                    )
                }
                let value = try updated(record[name] ?? .nothing, rest, type: property.type, change)
                let stored = try checked(value, as: property, of: structType)
                // `willSet` and `didSet` run for a change from outside, not while the value is
                // made.
                if let observers = structType.observers[name], !initializing {
                    var working = record
                    if let willSet = observers.willSet {
                        let receiver = Receiver(Value(record: working), mutable: true)
                        _ = try invoke(
                            willSet,
                            with: [willSet.parameters[0].name: stored],
                            receiver: receiver
                        )
                        if let changed = receiver.value.record { working = changed }
                    }
                    let old = working[name] ?? .nothing
                    working[name] = stored
                    if let didSet = observers.didSet {
                        let receiver = Receiver(Value(record: working), mutable: true)
                        _ = try invoke(
                            didSet,
                            with: [didSet.parameters[0].name: old],
                            receiver: receiver
                        )
                        if let changed = receiver.value.record { working = changed }
                    }
                    return Value(record: working)
                }
                record[name] = stored
            } else {
                guard record[name] != nil || rest.isEmpty else {
                    throw RuntimeError("\(record.typeName ?? "Record") has no field '\(name)'")
                }
                record[name] = try updated(record[name] ?? .nothing, rest, type: nil, change)
            }
            return Value(record: record)
        case (.index(let indexExpr), .list(var items)):
            let index = try evaluate(indexExpr)
            guard case .int(let position) = index.storage else {
                throw RuntimeError("a list is indexed by Int, not \(index.typeName)")
            }
            guard items.indices.contains(position) else {
                throw RuntimeError("index \(position) is out of range for a list of \(items.count)")
            }
            items[position] = try updated(items[position], rest, type: nil, change)
            return .list(items)
        case (.index(let indexExpr), .dictionary(var dictionary)):
            let key = try evaluate(indexExpr)
            let current = dictionary[key] ?? .nothing
            let value =
                try rest.isEmpty ? change(current, type) : updated(current, rest, type: nil, change)
            dictionary[key] = value == .nothing ? nil : value
            return .dictionary(dictionary)
        case (.index(let indexExpr), _)
        where base.record.flatMap(structType(of:))?.subscriptGetters.isEmpty == false:
            let record = base.record!
            return try writeSubscript(
                record,
                structType(of: record)!,
                [Argument(value: indexExpr)],
                rest,
                change
            )
        case (.subscripted(let arguments), _)
        where base.record.flatMap(structType(of:))?.subscriptGetters.isEmpty == false:
            let record = base.record!
            return try writeSubscript(record, structType(of: record)!, arguments, rest, change)
        case (.index(let indexExpr), .object(let instance as ClassInstance)):
            return try writeSubscript(instance, [Argument(value: indexExpr)], rest, change)
        case (.subscripted(let arguments), .object(let instance as ClassInstance)):
            return try writeSubscript(instance, arguments, rest, change)
        case (.indexDefault(let keyExpr, let fallback), .dictionary(var dictionary)):
            let key = try evaluate(keyExpr)
            let current = try dictionary[key] ?? evaluate(fallback)
            let value =
                try rest.isEmpty ? change(current, type) : updated(current, rest, type: nil, change)
            dictionary[key] = value == .nothing ? nil : value
            return .dictionary(dictionary)
        case (.index(let indexExpr), _) where base.record != nil:
            var record = base.record!
            let key = try evaluate(indexExpr)
            guard case .string(let name) = key.storage else {
                throw RuntimeError("a record is indexed by String, not \(key.typeName)")
            }
            if structType(of: record) != nil {
                return try updated(
                    base,
                    [.member(name)] + rest,
                    type: type,
                    initializing: initializing,
                    change
                )
            }
            record[name] = try updated(record[name] ?? .nothing, rest, type: nil, change)
            return Value(record: record)
        case (.member(let name), .object(let instance as ClassInstance)):
            try updatedInstance(instance, name, rest: rest, initializing: initializing, change) {
                current,
                remaining,
                type in
                try self.updated(current, remaining, type: type, change)
            }
            return base
        case (.member(let name), .object(let type as ClassType)):
            // `Counter.total += 1`: a static var of the class.
            guard let slot = type.chain.lazy.compactMap({ $0.statics[name] }).first else {
                throw RuntimeError(
                    "cannot assign to '\(name)': \(type.name) has no static property '\(name)'"
                )
            }
            guard slot.mutable else {
                throw RuntimeError("cannot assign to '\(type.name).\(name)': it's a 'let' constant")
            }
            slot.value = try updated(slot.value, rest, type: nil, change)
            return base
        case (.member(let name), .object(let type as StructType))
        where type.staticSetters[name] != nil && rest.isEmpty:
            // A computed `static var` with a setter: the new value goes through it.
            // What it holds now is read only to change it (`+=`); `= v` only sets.
            let current =
                task.assigningPlainly
                ? Value.nothing
                : try type.staticComputed[name].map { try invoke($0, with: [:]) } ?? .nothing
            let newValue = try change(current, type.staticProperty(name)?.type)
            let setter = type.staticSetters[name]!
            _ = try invoke(setter, with: [setter.parameters[0].name: newValue])
            return base
        case (.member(let name), .object(let type as StructType)):
            guard let slot = type.statics[name] else {
                let what =
                    type.staticComputed[name] != nil
                    ? "it's a computed property" : "\(type.name) has no static property '\(name)'"
                throw RuntimeError("cannot assign to '\(name)': \(what)")
            }
            guard slot.mutable else {
                throw RuntimeError("cannot assign to '\(type.name).\(name)': it's a 'let' constant")
            }
            let value = try updated(slot.value, rest, type: type.staticProperty(name)?.type, change)
            if let expected = type.staticProperty(name)?.type, rest.isEmpty,
                conform(value, to: expected) == nil
            {
                throw RuntimeError(
                    "\(type.name).\(name) must be \(expected), not \(value.typeName)"
                )
            }
            slot.value = value
            return base
        case (.member(let name), .object(let box as SwiftValue)):
            // A Swift property with a setter: get it, change it, set it on a copy.
            guard
                let setter = Bridge.types[box.typeName]?.members
                    .first(where: { $0.kind == .setter && $0.name == name }),
                let current = try bridgedProperty(name, of: base)
            else {
                throw RuntimeError("cannot assign to '\(name)' of \(base.typeName)")
            }
            let value = try updated(current, rest, type: setter.parameters[0].type, change)
            let function = Function(
                name: name,
                parameters: setter.parameters,
                returnType: nil,
                body: setter.body
            )
            guard
                case .list(let parts) = try invoke(
                    function,
                    with: ["self": base, "newValue": value]
                )
                .storage,
                parts.count == 2
            else {
                throw RuntimeError("\(box.typeName).\(name) gave back no receiver")
            }
            return parts[1]
        case (.member(let name), _):
            throw RuntimeError("cannot assign to '\(name)' of \(base.typeName)")
        case (.index, _), (.indexDefault, _), (.subscripted, _):
            throw RuntimeError("cannot assign into \(base.typeName) by index")
        }
    }
    // swiftlint:enable cyclomatic_complexity function_body_length
}
