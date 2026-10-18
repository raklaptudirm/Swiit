import Foundation
@_spi(Layer) import SwiitKit

/// A struct's definition. Its values are records with its name as their
/// type, so they're values like Swift's structs, and tables, `where`,
/// `select` and `to json` work on them as on any record; what the type adds
/// (computed properties, methods, initializers) is looked up through here.
public final class StructType: SwiitObject, @unchecked Sendable { // safe: its state is touched only holding the interpreter lock
    public let name: String
    /// Stored properties, in declaration order: the order of a value's fields.
    let stored: [PropertyDecl]
    public let computed: [String: Function]
    public let methods: [String: OverloadSet]
    /// Custom initializers; without any, the memberwise one.
    let initializers: OverloadSet?
    public let memberwise: Function
    /// The protocols it declares: `struct Point: Equatable`.
    public let conformances: [String]
    /// `static let` and `static var`: declared, with their types once checked;
    /// the stored ones' values are in `statics`.
    let staticProperties: [PropertyDecl]
    let staticComputed: [String: Function]
    /// The setters of `static var`s that are computed.
    var staticSetters: [String: Function] = [:]
    let staticMethods: [String: OverloadSet]
    public var statics: [String: StaticValue] = [:]
    /// `subscript(…)`: each getter, and the setter of the same position if it has one (its
    /// parameters are the getter's, then the new value).
    var subscriptGetters: [Function] = []
    var subscriptSetters: [Function?] = []
    /// What setting a computed property runs, with its value as the one parameter.
    var setters: [String: Function] = [:]
    /// What runs before and after a stored property changes.
    var observers: [String: (willSet: Function?, didSet: Function?)] = [:]

    /// A stored static property's value, kept on the type.
    public final class StaticValue {
        public var value: Value
        public let mutable: Bool

        init(_ value: Value, mutable: Bool) {
            self.value = value
            self.mutable = mutable
        }
    }

    init(name: String, stored: [PropertyDecl], computed: [String: Function], methods: [String: OverloadSet],
         initializers: OverloadSet?, memberwise: Function, conformances: [String] = [],
         staticProperties: [PropertyDecl] = [], staticComputed: [String: Function] = [:],
         staticMethods: [String: OverloadSet] = [:]) {
        self.name = name
        self.conformances = conformances
        self.staticProperties = staticProperties
        self.staticComputed = staticComputed
        self.staticMethods = staticMethods
        self.stored = stored
        self.computed = computed
        self.methods = methods
        self.initializers = initializers
        self.memberwise = memberwise
    }

    func property(_ name: String) -> PropertyDecl? {
        stored.first { $0.name == name }
    }

    func staticProperty(_ name: String) -> PropertyDecl? {
        staticProperties.first { $0.name == name }
    }

    public var typeName: String { "struct" }
    public var memberNames: [String] { [] }
    public func member(_ name: String) -> Value? { nil }
    public var fields: Record? { nil }
    public var description: String { "struct \(name)" }
}

/// `self` for a method: its value going in, and as the method left it.
public final class Receiver {
    public var value: Value
    public let mutable: Bool
    /// In an `init`, which may also set `let` properties.
    let initializing: Bool

    public init(_ value: Value, mutable: Bool, initializing: Bool = false) {
        self.value = value
        self.mutable = mutable
        self.initializing = initializing
    }
}

extension Interpreter {
    // MARK: Declaring

    /// `natives`: Swift bodies for the methods the prelude declares without
    /// one, by `Type.method`.
    func declare(_ decl: StructDecl, natives: [String: FunctionBody] = [:]) throws {
        var computed: [String: Function] = [:]
        for property in decl.properties {
            guard let getter = property.getter else { continue }
            computed[property.name] = Function(
                name: property.name, parameters: [], returnType: property.type, body: .swiit(getter),
                captured: captureScopes(property.getterNames)
            )
        }
        var methods: [String: [Function]] = [:]
        for method in decl.methods {
            methods[method.name, default: []].append(Function(
                name: method.name, parameters: method.parameters, returnType: method.returnType,
                body: natives["\(decl.name).\(method.name)"] ?? .swiit(method.body), captured: captureScopes(method.names),
                documentation: method.documentation,
                isMutating: method.isMutating, isThrowing: method.isThrowing
            ))
        }
        let initializers = decl.initializers.map { initializer in
            Function(
                name: "\(decl.name).init", parameters: initializer.parameters, returnType: nil,
                body: .swiit(initializer.body), captured: captureScopes(initializer.names), documentation: initializer.documentation,
                isMutating: true, isThrowing: initializer.isThrowing, isFailable: initializer.isFailable
            )
        }
        let stored = decl.properties.filter { $0.getter == nil }
        // As in Swift: every stored property, except a `let` that already
        // has its value, in order; one with a default may be left out.
        let memberwise = Function(
            name: decl.name,
            parameters: stored.filter { $0.mutable || $0.defaultValue == nil }.map { property in
                Parameter(label: property.name, name: property.name, type: property.type ?? .any,
                          defaultValue: property.defaultValue)
            },
            returnType: nil, body: .native { _, _ in .nothing }, captured: captureScopes(NamesUsed())
        )
        var staticComputed: [String: Function] = [:]
        var staticSetters: [String: Function] = [:]
        for property in decl.staticProperties {
            guard let getter = property.getter else { continue }
            staticComputed[property.name] = Function(
                name: property.name, parameters: [], returnType: property.type, body: .swiit(getter),
                captured: captureScopes(property.getterNames)
            )
            if let setter = property.setter {
                staticSetters[property.name] = Function(
                    name: property.name, parameters: [Parameter(name: property.setterName, type: property.type ?? .any)], returnType: nil,
                    body: .swiit(setter), captured: captureScopes(property.setterNames)
                )
            }
        }
        var staticMethods: [String: [Function]] = [:]
        for method in decl.staticMethods {
            staticMethods[method.name, default: []].append(Function(
                name: method.name, parameters: method.parameters, returnType: method.returnType,
                body: .swiit(method.body), captured: captureScopes(method.names), documentation: method.documentation,
                isThrowing: method.isThrowing
            ))
        }
        let type = StructType(
            name: decl.name, stored: stored, computed: computed,
            methods: methods.mapValues { OverloadSet(name: $0[0].name!, candidates: $0) },
            initializers: initializers.isEmpty ? nil : OverloadSet(name: "\(decl.name).init", candidates: initializers),
            memberwise: memberwise, conformances: decl.conformances,
            staticProperties: decl.staticProperties, staticComputed: staticComputed,
            staticMethods: staticMethods.mapValues { OverloadSet(name: $0[0].name!, candidates: $0) }
        )
        type.staticSetters = staticSetters
        for declared in decl.subscripts {
            type.subscriptGetters.append(Function(
                name: "subscript", parameters: declared.parameters, returnType: declared.returnType, body: .swiit(declared.getter),
                captured: captureScopes(declared.getterNames)
            ))
            type.subscriptSetters.append(declared.setter.map { setter in
                Function(
                    name: "subscript", parameters: declared.parameters + [Parameter(name: declared.setterName, type: declared.returnType)],
                    returnType: nil, body: .swiit(setter), captured: captureScopes(declared.setterNames), isMutating: true
                )
            })
        }
        for property in decl.properties {
            if let setter = property.setter {
                type.setters[property.name] = Function(
                    name: property.name, parameters: [Parameter(name: property.setterName, type: property.type ?? .any)], returnType: nil,
                    body: .swiit(setter), captured: captureScopes(property.setterNames), isMutating: true
                )
            }
            if property.willSet != nil || property.didSet != nil {
                func observer(_ body: Program?, _ parameter: String, _ names: NamesUsed) -> Function? {
                    body.map { body in
                        Function(name: property.name, parameters: [Parameter(name: parameter, type: property.type ?? .any)], returnType: nil,
                                 body: .swiit(body), captured: captureScopes(names), isMutating: true)
                    }
                }
                type.observers[property.name] = (observer(property.willSet, property.willSetName, property.willSetNames),
                                                 observer(property.didSet, property.didSetName, property.didSetNames))
            }
        }
        scopes[scopes.count - 1].bindings[decl.name] = Binding(value: .object(type), mutable: false)
        // Bound first, so a static value can be made of the type itself.
        for property in decl.staticProperties where property.getter == nil {
            guard let expr = property.defaultValue else { continue }
            var value = try evaluate(expr, expecting: property.type)
            if let expected = property.type {
                guard let conforming = conform(value, to: expected) else {
                    throw RuntimeError("\(decl.name).\(property.name) must be \(expected), not \(value.typeName)")
                }
                value = conforming
            }
            type.statics[property.name] = StructType.StaticValue(value, mutable: property.mutable)
        }
    }

    func structType(named name: String) -> StructType? {
        guard case .object(let type as StructType)? = lookup(name)?.value else { return nil }
        return type
    }

    func structType(of record: Record) -> StructType? {
        record.typeName.flatMap(structType(named:))
    }

    // MARK: Making values

    /// `Point(x: 1, y: 2)`: through an `init` the struct declares, or the
    /// memberwise one.
    func construct(_ type: StructType, _ arguments: [Argument], overload: Int? = nil) throws -> Value {
        let values = try arguments.map { argument -> Argument in
            if case .caseLiteral = argument.value { return argument }
            return Argument(label: argument.label, value: .literal(try evaluate(argument.value)))
        }
        // What an extension adds is tried when the type's own don't take the arguments.
        var chosenInitializers = type.initializers
        var overload = overload
        if let added = typeExtensions[type.name]?.initializers {
            let ownTakes: Bool
            if let own = type.initializers {
                ownTakes = (try? resolve(narrowed(own, overload)) { try self.bind(values, to: $0) }) != nil
            } else {
                ownTakes = (try? bind(values, to: type.memberwise)) != nil
            }
            if !ownTakes { chosenInitializers = added; overload = nil }
        }
        guard let initializers = chosenInitializers else {
            let bound = try bind(values, to: type.memberwise).bindings
            var record = Record(typeName: type.name)
            for property in type.stored {
                if let value = bound[property.name] {
                    record[property.name] = value
                } else if let defaultValue = property.defaultValue {
                    record[property.name] = try storedValue(defaultValue, for: property, of: type)
                }
            }
            return .record(record)
        }

        let (initializer, bindings) = try resolve(narrowed(initializers, overload)) { try self.bind(values, to: $0) }
        // Defaults first, then whatever the initializer sets.
        var start = Record(typeName: type.name)
        for property in type.stored {
            if let defaultValue = property.defaultValue {
                start[property.name] = try storedValue(defaultValue, for: property, of: type)
            }
        }
        let receiver = Receiver(.record(start), mutable: true, initializing: true)
        task.failedInit = false
        _ = try invoke(initializer, with: bindings, receiver: receiver)
        if task.failedInit {
            task.failedInit = false
            return .nothing
        }
        guard case .record(let made) = receiver.value else {
            throw RuntimeError("\(type.name).init must leave self a \(type.name)")
        }
        // In declaration order, whatever order the initializer set them in.
        var record = Record(typeName: type.name)
        for property in type.stored {
            guard let value = made[property.name] else {
                throw RuntimeError("\(type.name).init must set '\(property.name)'")
            }
            record[property.name] = value
        }
        return .record(record)
    }

    private func storedValue(_ expr: Expr, for property: PropertyDecl, of type: StructType) throws -> Value {
        let value = try evaluate(expr, expecting: property.type)
        return try checked(value, as: property, of: type)
    }

    func checked(_ value: Value, as property: PropertyDecl, of type: StructType) throws -> Value {
        guard let expected = property.type else { return value }
        guard let conforming = conform(value, to: expected) else {
            throw RuntimeError("\(type.name).\(property.name) must be \(expected), not \(value.typeName)")
        }
        return conforming
    }

    // MARK: Members

    /// A computed property's value, or a method as a function value; nil if
    /// the type has neither by that name.
    func structMember(_ name: String, of record: Record, _ type: StructType) throws -> Value? {
        if let getter = type.computed[name] {
            return try invoke(getter, with: [:], receiver: Receiver(.record(record), mutable: false))
        }
        guard let methods = type.methods[name] else { return nil }
        // `let f = p.describe`: the method with `p` as `self`.
        let bound = methods.candidates.map { method in
            Function(name: method.name, parameters: method.parameters, returnType: method.returnType,
                     body: .native { shell, arguments in
                         guard !method.isMutating else {
                             throw RuntimeError("mutating method '\(name)' must be called on a variable, as in p.\(name)(…)")
                         }
                         return try shell.invoke(method, with: arguments, receiver: Receiver(.record(record), mutable: false))
                     }, documentation: method.documentation, isMutating: method.isMutating)
        }
        return .function(OverloadSet(name: name, candidates: bound))
    }

    /// `Point.origin`, `Point.count`, or a static method as a function value;
    /// nil if the type has no static member by that name.
    func staticMember(_ name: String, of type: StructType) throws -> Value? {
        if let getter = type.staticComputed[name] { return try invoke(getter, with: [:]) }
        if let slot = type.statics[name] { return slot.value }
        return type.staticMethods[name].map(Value.function)
    }

    /// `grid[1, 2]`: a struct's subscript read, with `self` the value.
    func readSubscript(_ instance: ClassInstance, _ arguments: [Argument]) throws -> Value {
        guard let owner = instance.type.subscriptOwner else { throw RuntimeError("\(instance.type.name) has no subscript") }
        let values = try arguments.map { Argument(label: $0.label, value: .literal(try evaluate($0.value))) }
        let (getter, bindings) = try resolve(OverloadSet(name: "subscript", candidates: owner.subscriptGetters)) { try self.bind(values, to: $0) }
        return try invoke(getter, with: bindings, receiver: Receiver(.object(instance), mutable: true))
    }

    func writeSubscript(
        _ instance: ClassInstance, _ arguments: [Argument], _ rest: ArraySlice<Assignment.Step>,
        _ change: (Value, TypeAnnotation?) throws -> Value
    ) throws -> Value {
        guard let owner = instance.type.subscriptOwner else { throw RuntimeError("\(instance.type.name) has no subscript") }
        let values = try arguments.map { Argument(label: $0.label, value: .literal(try evaluate($0.value))) }
        let (getter, bindings) = try resolve(OverloadSet(name: "subscript", candidates: owner.subscriptGetters)) { try self.bind(values, to: $0) }
        guard let position = owner.subscriptGetters.firstIndex(where: { $0 === getter }), let setter = owner.subscriptSetters[position] else {
            throw RuntimeError("cannot assign through \(instance.type.name)'s subscript: it's get-only")
        }
        let receiver = Receiver(.object(instance), mutable: true)
        let current = try invoke(getter, with: bindings, receiver: receiver)
        let updatedValue = try rest.isEmpty ? change(current, getter.returnType) : updated(current, rest, type: getter.returnType, change)
        var all = bindings
        all[setter.parameters[setter.parameters.count - 1].name] = updatedValue
        _ = try invoke(setter, with: all, receiver: receiver)
        return .object(instance)
    }

    func readSubscript(_ record: Record, _ type: StructType, _ arguments: [Argument]) throws -> Value {
        let values = try arguments.map { Argument(label: $0.label, value: .literal(try evaluate($0.value))) }
        let (getter, bindings) = try resolve(OverloadSet(name: "subscript", candidates: type.subscriptGetters)) { try self.bind(values, to: $0) }
        return try invoke(getter, with: bindings, receiver: Receiver(.record(record), mutable: false))
    }

    /// `grid[1, 2] = v` (or with `rest`, a change deeper inside it): the value through the subscript's setter.
    func writeSubscript(
        _ record: Record, _ type: StructType, _ arguments: [Argument], _ rest: ArraySlice<Assignment.Step>,
        _ change: (Value, TypeAnnotation?) throws -> Value
    ) throws -> Value {
        let values = try arguments.map { Argument(label: $0.label, value: .literal(try evaluate($0.value))) }
        let (getter, bindings) = try resolve(OverloadSet(name: "subscript", candidates: type.subscriptGetters)) { try self.bind(values, to: $0) }
        guard let position = type.subscriptGetters.firstIndex(where: { $0 === getter }), let setter = type.subscriptSetters[position] else {
            throw RuntimeError("cannot assign through \(type.name)'s subscript: it's get-only")
        }
        let current = try invoke(getter, with: bindings, receiver: Receiver(.record(record), mutable: false))
        let updatedValue = try rest.isEmpty ? change(current, getter.returnType) : updated(current, rest, type: getter.returnType, change)
        var all = bindings
        all[setter.parameters[setter.parameters.count - 1].name] = updatedValue
        let receiver = Receiver(.record(record), mutable: true)
        _ = try invoke(setter, with: all, receiver: receiver)
        return receiver.value
    }

    /// `Point.make(1)`.
    func callStatic(_ methods: OverloadSet, _ arguments: [Argument]) throws -> Value {
        let values = try arguments.map { argument -> Argument in
            if case .caseLiteral = argument.value { return argument }
            return Argument(label: argument.label, value: .literal(try evaluate(argument.value)))
        }
        let (method, bindings) = try resolve(methods) { try self.bind(values, to: $0) }
        return try invoke(method, with: bindings)
    }

    /// `p.move(by: 1)`. A mutating method changes `p` itself, so `p` must
    /// be a `var` (or a part of one).
    func callMethod(_ methods: OverloadSet, of base: Value, at baseExpr: Expr, _ arguments: [Argument]) throws -> Value {
        let values = try arguments.map { argument -> Argument in
            if case .caseLiteral = argument.value { return argument }
            return Argument(label: argument.label, value: .literal(try evaluate(argument.value)))
        }
        let (method, bindings) = try resolve(methods) { try self.bind(values, to: $0) }
        guard method.isMutating else {
            return try invoke(method, with: bindings, receiver: Receiver(base, mutable: false))
        }
        guard let (root, path) = lvalue(baseExpr) else {
            throw RuntimeError("cannot use mutating method '\(methods.name)' on a value that isn't in a variable")
        }
        try checkAssignable(root, what: "use mutating method '\(methods.name)' on")
        let receiver = Receiver(base, mutable: true)
        let result = try invoke(method, with: bindings, receiver: receiver)
        try update(root, path) { _, _ in receiver.value }
        return result
    }

    /// Puts what a mutating method made of `receiver` back where it came
    /// from: a variable, or a part of one.
    func mutate(_ receiver: Expr, by method: String, _ change: (Value) throws -> Value) throws {
        guard let (root, path) = lvalue(receiver) else {
            throw RuntimeError("cannot use mutating method '\(method)' on a value that isn't in a variable")
        }
        try checkAssignable(root, what: "use mutating method '\(method)' on")
        try update(root, path) { current, _ in try change(current) }
    }

    /// `p`, `p.a`, `xs[0].b`: somewhere a value can be put back.
    func lvalue(_ expr: Expr) -> (String, [Assignment.Step])? {
        switch expr {
        case .variable(let name):
            return (name, [])
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

    // MARK: Assigning

    /// `x = v`, `p.x += 1`, `xs[0] = v`, `r["k"] = v`.
    func assign(_ assignment: Assignment) throws {
        // `Point.count += 1`: a static var, set through its type.
        // A change inside an instance is to the instance itself, which the variable holding it needn't allow.
        var holdsInstance = false
        if !assignment.path.isEmpty {
            switch lookup(assignment.root)?.value {
            case .object(is ClassInstance)?, .object(is ClassType)?: holdsInstance = true
            default: break
            }
        }
        if structType(named: assignment.root) == nil, !(lookup(assignment.root)?.value.isDynamicObject ?? false), !holdsInstance {
            try checkAssignable(assignment.root, what: "assign to")
        }
        // Where it can be, the change is made where the value is, not on a copy of it (see Interpreter+InPlace.swift).
        if let place = try plainPlace(assignment.root, assignment.path, op: assignment.op) {
            var value = try evaluate(assignment.value, expecting: place.type)
            // A property's type is checked for what is put in it; a collection changed in it keeps its type, and isn't walked again.
            if assignment.op == nil, let validate = place.validate { value = try validate(value) }
            try withPlace(assignment.root, place) { slot in
                guard let op = assignment.op else { slot = value; return }
                try applyInPlace(op, &slot, value)
                switch slot {
                case .int, .double, .bool: if let validate = place.validate { slot = try validate(slot) }
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
            if assignment.path.isEmpty, case .object(is WeakReference) = current, assignment.op == nil {
                if case .object(let instance as ClassInstance) = value { return .object(WeakReference(instance)) }
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
            default:
                throw RuntimeError("only a variable can be passed with &")
            }
        }
    }

    func checkAssignable(_ root: String, what: String) throws {
        guard let binding = lookup(root) else { throw RuntimeError("no variable named '\(root)'") }
        guard binding.mutable else {
            if root == "self" {
                throw RuntimeError("cannot \(what) self here: it's only changed by a mutating method")
            }
            throw RuntimeError("cannot \(what) '\(root)': it's a 'let' constant")
        }
    }

    /// Replaces the value at `path` in the variable `root` with what
    /// `change` makes of it (given the current value and the type the
    /// place holds, if known).
    private func update(
        _ root: String, _ path: [Assignment.Step], _ change: (Value, TypeAnnotation?) throws -> Value
    ) throws {
        guard let scope = scopeHolding(root) else {
            throw RuntimeError("no variable named '\(root)'")
        }
        let current = scope.bindings[root]!.value
        let initializing = scope.bindings[root]!.special == .initializing
        scope.bindings[root]!.value = try updated(current, path[...], type: nil, initializing: initializing, change)
    }

    /// `initializing`: this is `self` in an `init`, whose own `let`
    /// properties can be set.
    private func updated(
        _ base: Value, _ path: ArraySlice<Assignment.Step>, type: TypeAnnotation?, initializing: Bool = false,
        _ change: (Value, TypeAnnotation?) throws -> Value
    ) throws -> Value {
        guard let step = path.first else { return try change(base, type) }
        let rest = path.dropFirst()
        switch (step, base) {
        case (.optionalChain, _):
            // Nothing is nil's to change, and what would have been assigned isn't worked out.
            guard base != .nothing else { return base }
            return try updated(base, rest, type: type, initializing: initializing, change)
        case (.unwrap, _):
            guard base != .nothing else { throw RuntimeError("nil was unwrapped with '!'") }
            return try updated(base, rest, type: type, initializing: initializing, change)
        case (.member(let name), .record(var record)):
            if let structType = structType(of: record) {
                // A computed property with a setter: the new value goes through it.
                if let setter = structType.setters[name] ?? extensionChain(of: base).lazy.compactMap({ $0.setters[name] }).first {
                    // `x.0 = 1` through a computed `x`: its value is read, changed inside, and set back.
                    let current = task.assigningPlainly && rest.isEmpty ? Value.nothing : try structMember(name, of: record, structType) ?? .nothing
                    let receiver = Receiver(.record(record), mutable: true)
                    let returnType = structType.computed[name]?.returnType
                    let newValue = try rest.isEmpty ? change(current, returnType) : updated(current, rest, type: returnType, change)
                    let parameter = setter.parameters[0]
                    _ = try invoke(setter, with: [parameter.name: try checked(newValue, for: parameter, of: name)], receiver: receiver)
                    return receiver.value
                }
                guard let property = structType.property(name) else {
                    let what = structType.computed[name] != nil ? "it's a computed property" : "\(structType.name) has no property '\(name)'"
                    throw RuntimeError("cannot assign to '\(name)': \(what)")
                }
                guard property.mutable || (initializing && path.count == 1) else {
                    throw RuntimeError("cannot assign to '\(name)': it's a 'let' property of \(structType.name)")
                }
                let value = try updated(record[name] ?? .nothing, rest, type: property.type, change)
                let stored = try checked(value, as: property, of: structType)
                // `willSet` and `didSet` run for a change from outside, not while the value is made.
                if let observers = structType.observers[name], !initializing {
                    var working = record
                    if let willSet = observers.willSet {
                        let receiver = Receiver(.record(working), mutable: true)
                        _ = try invoke(willSet, with: [willSet.parameters[0].name: stored], receiver: receiver)
                        if case .record(let changed) = receiver.value { working = changed }
                    }
                    let old = working[name] ?? .nothing
                    working[name] = stored
                    if let didSet = observers.didSet {
                        let receiver = Receiver(.record(working), mutable: true)
                        _ = try invoke(didSet, with: [didSet.parameters[0].name: old], receiver: receiver)
                        if case .record(let changed) = receiver.value { working = changed }
                    }
                    return .record(working)
                }
                record[name] = stored
            } else {
                guard record[name] != nil || rest.isEmpty else {
                    throw RuntimeError("\(record.typeName ?? "Record") has no field '\(name)'")
                }
                record[name] = try updated(record[name] ?? .nothing, rest, type: nil, change)
            }
            return .record(record)
        case (.index(let indexExpr), .list(var items)):
            let index = try evaluate(indexExpr)
            guard case .int(let position) = index else { throw RuntimeError("a list is indexed by Int, not \(index.typeName)") }
            guard items.indices.contains(position) else {
                throw RuntimeError("index \(position) is out of range for a list of \(items.count)")
            }
            items[position] = try updated(items[position], rest, type: nil, change)
            return .list(items)
        case (.index(let indexExpr), .dictionary(var dictionary)):
            let key = try evaluate(indexExpr)
            let current = dictionary[key] ?? .nothing
            let value = try rest.isEmpty ? change(current, type) : updated(current, rest, type: nil, change)
            dictionary[key] = value == .nothing ? nil : value
            return .dictionary(dictionary)
        case (.index(let indexExpr), .record(let record)) where structType(of: record)?.subscriptGetters.isEmpty == false:
            return try writeSubscript(record, structType(of: record)!, [Argument(value: indexExpr)], rest, change)
        case (.subscripted(let arguments), .record(let record)) where structType(of: record)?.subscriptGetters.isEmpty == false:
            return try writeSubscript(record, structType(of: record)!, arguments, rest, change)
        case (.index(let indexExpr), .object(let instance as ClassInstance)):
            return try writeSubscript(instance, [Argument(value: indexExpr)], rest, change)
        case (.subscripted(let arguments), .object(let instance as ClassInstance)):
            return try writeSubscript(instance, arguments, rest, change)
        case (.indexDefault(let keyExpr, let fallback), .dictionary(var dictionary)):
            let key = try evaluate(keyExpr)
            let current = try dictionary[key] ?? evaluate(fallback)
            let value = try rest.isEmpty ? change(current, type) : updated(current, rest, type: nil, change)
            dictionary[key] = value == .nothing ? nil : value
            return .dictionary(dictionary)
        case (.index(let indexExpr), .record(var record)):
            let key = try evaluate(indexExpr)
            guard case .string(let name) = key else { throw RuntimeError("a record is indexed by String, not \(key.typeName)") }
            if structType(of: record) != nil {
                return try updated(base, [.member(name)] + rest, type: type, initializing: initializing, change)
            }
            record[name] = try updated(record[name] ?? .nothing, rest, type: nil, change)
            return .record(record)
        case (.member(let name), .object(let instance as ClassInstance)):
            try updatedInstance(instance, name, rest: rest, initializing: initializing, change) { current, remaining, type in
                try self.updated(current, remaining, type: type, change)
            }
            return base
        case (.member(let name), .object(let type as ClassType)):
            // `Counter.total += 1`: a static var of the class.
            guard let slot = type.chain.lazy.compactMap({ $0.statics[name] }).first else {
                throw RuntimeError("cannot assign to '\(name)': \(type.name) has no static property '\(name)'")
            }
            guard slot.mutable else { throw RuntimeError("cannot assign to '\(type.name).\(name)': it's a 'let' constant") }
            slot.value = try updated(slot.value, rest, type: nil, change)
            return base
        case (.member(let name), .object(let type as StructType)) where type.staticSetters[name] != nil && rest.isEmpty:
            // A computed `static var` with a setter: the new value goes through it.
            // What it holds now is read only to change it (`+=`); `= v` only sets.
            let current = task.assigningPlainly ? Value.nothing : try type.staticComputed[name].map { try invoke($0, with: [:]) } ?? .nothing
            let newValue = try change(current, type.staticProperty(name)?.type)
            let setter = type.staticSetters[name]!
            _ = try invoke(setter, with: [setter.parameters[0].name: newValue])
            return base
        case (.member(let name), .object(let type as StructType)):
            guard let slot = type.statics[name] else {
                let what = type.staticComputed[name] != nil ? "it's a computed property" : "\(type.name) has no static property '\(name)'"
                throw RuntimeError("cannot assign to '\(name)': \(what)")
            }
            guard slot.mutable else { throw RuntimeError("cannot assign to '\(type.name).\(name)': it's a 'let' constant") }
            let value = try updated(slot.value, rest, type: type.staticProperty(name)?.type, change)
            if let expected = type.staticProperty(name)?.type, rest.isEmpty, conform(value, to: expected) == nil {
                throw RuntimeError("\(type.name).\(name) must be \(expected), not \(value.typeName)")
            }
            slot.value = value
            return base
        case (.member(let name), .object(let box as SwiftValue)):
            // A Swift property with a setter: get it, change it, set it on a copy.
            guard let setter = Bridge.types[box.typeName]?.members.first(where: { $0.kind == .setter && $0.name == name }),
                  let current = try bridgedProperty(name, of: base) else {
                throw RuntimeError("cannot assign to '\(name)' of \(base.typeName)")
            }
            let value = try updated(current, rest, type: setter.parameters[0].type, change)
            let function = Function(name: name, parameters: setter.parameters, returnType: nil, body: setter.body)
            guard case .list(let parts) = try invoke(function, with: ["self": base, "newValue": value]), parts.count == 2 else {
                throw RuntimeError("\(box.typeName).\(name) gave back no receiver")
            }
            return parts[1]
        case (.member(let name), .object(let object as DynamicObject)):
            guard rest.isEmpty else { throw RuntimeError("cannot assign into \(object.typeName).\(name)") }
            try object.write(name, try change(try object.read(name), nil))
            return base
        case (.index(let indexExpr), .object(let object as DynamicObject)):
            let key = try evaluate(indexExpr)
            guard case .string(let name) = key, rest.isEmpty else {
                throw RuntimeError("\(object.typeName) is indexed by name, not \(key.typeName)")
            }
            try object.write(name, try change(try object.read(name), nil))
            return base
        case (.member(let name), _):
            throw RuntimeError("cannot assign to '\(name)' of \(base.typeName)")
        case (.index, _), (.indexDefault, _), (.subscripted, _):
            throw RuntimeError("cannot assign into \(base.typeName) by index")
        }
    }
}

@_spi(Layer) extension StructType: LanguageObject {}
