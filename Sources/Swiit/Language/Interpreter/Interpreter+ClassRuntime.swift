import Foundation
import SwiitKit

/// A reference held without keeping what it refers to alive: what a `weak` property stores.
final class WeakReference: SwiitObject, @unchecked Sendable {
    weak var target: ClassInstance?
    init(_ target: ClassInstance?) { self.target = target }
    var typeName: String { "weak" }
    var memberNames: [String] { [] }
    func member(_ name: String) -> Value? { nil }
    var fields: Record? { nil }
    var description: String { target.map { "\($0)" } ?? "nil" }
}

extension Interpreter {
    // MARK: Declaring

    func classType(named name: String) -> ClassType? {
        guard case .object(let type as ClassType)? = lookup(name)?.value else { return nil }
        return type
    }

    /// `class Dog: Animal { … }`, `actor Counter { … }`.
    func declare(_ decl: ClassDecl) throws {
        var conformances = decl.inherited
        var superclass: ClassType?
        if let first = decl.inherited.first, let found = classType(named: first) {
            superclass = found
            conformances.removeFirst()
        }
        let members = decl.members
        let type = ClassType(
            name: decl.name, superclass: superclass, isActor: decl.isActor, stored: members.properties.filter { $0.getter == nil },
            staticProperties: members.staticProperties, conformances: conformances
        )
        func make(_ function: Function) -> Function { function.owner = type; return function }
        for property in members.properties {
            if let getter = property.getter {
                type.computed[property.name] = make(Function(
                    name: property.name, parameters: [], returnType: property.type, body: .swiit(getter), captured: captureScopes(property.getterNames)
                ))
            }
            if let setter = property.setter {
                type.setters[property.name] = make(Function(
                    name: property.name, parameters: [Parameter(name: property.setterName, type: property.type ?? .any)], returnType: nil,
                    body: .swiit(setter), captured: captureScopes(property.setterNames), isMutating: true
                ))
            }
            if property.willSet != nil || property.didSet != nil {
                func observer(_ body: Program?, _ parameter: String, _ names: NamesUsed) -> Function? {
                    body.map { make(Function(name: property.name, parameters: [Parameter(name: parameter, type: property.type ?? .any)], returnType: nil,
                                             body: .swiit($0), captured: captureScopes(names), isMutating: true)) }
                }
                type.observers[property.name] = (observer(property.willSet, property.willSetName, property.willSetNames),
                                                 observer(property.didSet, property.didSetName, property.didSetNames))
            }
        }
        for method in members.methods {
            type.methods[method.name, default: []].append(make(Function(
                name: method.name, parameters: method.parameters, returnType: method.returnType, body: .swiit(method.body),
                captured: captureScopes(method.names), documentation: method.documentation,
                isThrowing: method.isThrowing, effect: method.effect
            )))
        }
        for initializer in members.initializers {
            type.initializers.append(make(Function(
                name: "\(decl.name).init", parameters: initializer.parameters, returnType: nil, body: .swiit(initializer.body),
                captured: captureScopes(initializer.names), documentation: initializer.documentation,
                isMutating: true, isThrowing: initializer.isThrowing, isFailable: initializer.isFailable, isConvenience: initializer.isConvenience
            )))
        }
        for declared in members.subscripts {
            type.subscriptGetters.append(make(Function(
                name: "subscript", parameters: declared.parameters, returnType: declared.returnType, body: .swiit(declared.getter),
                captured: captureScopes(declared.getterNames)
            )))
            type.subscriptSetters.append(declared.setter.map { setter in
                make(Function(
                    name: "subscript", parameters: declared.parameters + [Parameter(name: declared.setterName, type: declared.returnType)],
                    returnType: nil, body: .swiit(setter), captured: captureScopes(declared.setterNames), isMutating: true
                ))
            })
        }
        for property in members.staticProperties {
            if let getter = property.getter {
                type.staticComputed[property.name] = make(Function(
                    name: property.name, parameters: [], returnType: property.type, body: .swiit(getter), captured: captureScopes(property.getterNames)
                ))
            }
        }
        for method in members.staticMethods {
            type.staticMethods[method.name, default: []].append(make(Function(
                name: method.name, parameters: method.parameters, returnType: method.returnType, body: .swiit(method.body),
                captured: captureScopes(method.names), documentation: method.documentation, isThrowing: method.isThrowing
            )))
        }
        if let body = decl.deinitializer {
            type.deinitializer = make(Function(name: "deinit", parameters: [], returnType: nil, body: .swiit(body),
                                               captured: captureScopes(decl.deinitializerNames), isMutating: true))
        }
        scopes[scopes.count - 1].bindings[decl.name] = Binding(value: .object(type), mutable: false)
        // Bound first, so a static value can be made of the class itself.
        for property in members.staticProperties where property.getter == nil {
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

    // MARK: Making instances

    /// Every initializer an instance of the class may be made by: its own, or, if it declares no designated one, those it inherits.
    func initializers(of type: ClassType) -> [Function] {
        if type.initializers.contains(where: { !$0.isConvenience }) { return type.initializers }
        return type.initializers + (type.superclass.map(initializers(of:)) ?? [])
    }

    /// What a stored property starts as: its default, or nil if an optional `var`.
    private func initialValue(of property: PropertyDecl) throws -> Value? {
        if property.isLazy { return nil }
        if let defaultValue = property.defaultValue {
            let value = try evaluate(defaultValue, expecting: property.type)
            if let expected = property.type, let conforming = conform(value, to: expected) { return wrapped(conforming, property) }
            return wrapped(value, property)
        }
        if property.mutable, case .optional? = property.type { return .nothing }
        return nil
    }

    /// A `weak` property holds its value weakly.
    private func wrapped(_ value: Value, _ property: PropertyDecl) -> Value {
        if property.isWeak, case .object(let instance as ClassInstance) = value { return .object(WeakReference(instance)) }
        return value
    }

    func read(_ value: Value) -> Value {
        if case .object(let reference as WeakReference) = value { return reference.target.map { .object($0) } ?? .nothing }
        return value
    }

    /// `Dog(name: "Rex")`: an instance, made by the initializer the arguments choose.
    func construct(_ type: ClassType, _ arguments: [Argument], overload: Int? = nil) throws -> Value {
        let values = try arguments.map { argument -> Argument in
            if case .caseLiteral = argument.value { return argument }
            return Argument(label: argument.label, value: .literal(try evaluate(argument.value)))
        }
        let instance = ClassInstance(type: type)
        for property in type.allStored {
            if let value = try initialValue(of: property) { instance.storage[property.name] = value }
        }
        if type.chain.contains(where: { $0.deinitializer != nil }) {
            instance.onRelease = { [weak self] released in self?.release(released) }
        }
        let candidates = initializers(of: type)
        if candidates.isEmpty {
            guard values.isEmpty else { throw RuntimeError("\(type.name) has no initializer that takes arguments") }
        } else {
            let (initializer, bindings) = try resolve(OverloadSet(name: "\(type.name).init", candidates: candidates)) { try self.bind(values, to: $0) }
            task.failedInit = false
            try initialize(instance, with: initializer, bindings)
            if task.failedInit {
                task.failedInit = false
                return .nothing
            }
        }
        for property in type.allStored where instance.storage[property.name] == nil && !property.isLazy {
            throw RuntimeError("\(type.name).init must set '\(property.name)'")
        }
        return .object(instance)
    }

    /// Runs one initializer on an instance; a designated one then makes sure the superclass is initialized.
    private func initialize(_ instance: ClassInstance, with initializer: Function, _ bindings: [String: Value]) throws {
        let saved = task.calledSuperInit
        task.calledSuperInit = false
        defer { task.calledSuperInit = saved }
        let receiver = Receiver(.object(instance), mutable: true, initializing: true)
        _ = try invoke(initializer, with: bindings, receiver: receiver)
        // Without a `super.init(…)`, the superclass's `init()` runs after.
        if !initializer.isConvenience, !task.calledSuperInit, let owner = initializer.owner, let parent = owner.superclass, !task.failedInit {
            let inherited = self.initializers(of: parent)
            if let zero = inherited.first(where: { $0.parameters.allSatisfy { $0.hasDefault || $0.variadic } }) {
                try initialize(instance, with: zero, try bind([], to: zero).bindings)
            } else if !inherited.isEmpty {
                throw RuntimeError("\(owner.name).init must call super.init")
            }
        }
    }

    /// `self.init(…)` in a convenience initializer, `super.init(…)` in a designated one.
    func delegateInitializer(of instance: ClassInstance, in type: ClassType, _ arguments: [Argument], isSuper: Bool) throws {
        let values = try arguments.map { Argument(label: $0.label, value: .literal(try evaluate($0.value))) }
        let candidates = initializers(of: type)
        guard !candidates.isEmpty else {
            guard values.isEmpty else { throw RuntimeError("\(type.name) has no initializer that takes arguments") }
            if isSuper { task.calledSuperInit = true }
            return
        }
        let (initializer, bindings) = try resolve(OverloadSet(name: "\(type.name).init", candidates: candidates)) { try self.bind(values, to: $0) }
        if isSuper { task.calledSuperInit = true }
        try initialize(instance, with: initializer, bindings)
    }

    // MARK: Releasing

    /// An instance went away: its `deinit` runs at the next statement, not here, where the
    /// interpreter may be in the middle of changing its scopes.
    private func release(_ released: ClassInstance) {
        let clone = ClassInstance(type: released.type, storage: released.storage)
        deinitLock.lock()
        pendingDeinits.append(clone)
        hasPendingDeinits = true
        deinitLock.unlock()
    }

    func runPendingDeinits() {
        deinitLock.lock()
        let pending = pendingDeinits
        pendingDeinits = []
        hasPendingDeinits = false
        deinitLock.unlock()
        for instance in pending {
            for type in instance.type.chain {
                guard let deinitializer = type.deinitializer else { continue }
                do {
                    _ = try invoke(deinitializer, with: [:], receiver: Receiver(.object(instance), mutable: true))
                } catch {
                    report("error: \(error)")
                }
            }
        }
    }

    // MARK: Members

    /// A property, a computed property or a method of an instance, as a value; nil if it has none by that name.
    func classMember(_ name: String, of instance: ClassInstance) throws -> Value? {
        if let stored = instance.storage[name] { return read(stored) }
        // A `lazy var`, read for the first time: worked out now, with `self`.
        if let lazy = instance.type.allStored.first(where: { $0.name == name && $0.isLazy }), let expr = lazy.defaultValue {
            let function = Function(name: name, parameters: [], returnType: lazy.type, body: .swiit(Program(statements: [.returnStatement(expr)])),
                                    captured: captureScopes(NamesUsed()))
            let value = try invoke(function, with: [:], receiver: Receiver(.object(instance), mutable: true))
            instance.storage[name] = wrapped(value, lazy)
            return value
        }
        if let getter = instance.type.computedProperty(name) {
            return try invoke(getter, with: [:], receiver: Receiver(.object(instance), mutable: true))
        }
        let methods = instance.type.allMethods(name)
        guard !methods.isEmpty else { return nil }
        // `let f = obj.describe`: the method with `obj` as `self`.
        let bound = methods.map { method in
            Function(name: method.name, parameters: method.parameters, returnType: method.returnType,
                     body: .native { interpreter, arguments in
                         try interpreter.invoke(method, with: arguments, receiver: Receiver(.object(instance), mutable: true))
                     }, documentation: method.documentation)
        }
        return .function(OverloadSet(name: name, candidates: bound))
    }

    /// `Counter.shared`, `Counter.make`: what a class has as static members, its superclasses' included.
    func classStaticMember(_ name: String, of type: ClassType) throws -> Value? {
        for next in type.chain {
            if let getter = next.staticComputed[name] { return try invoke(getter, with: [:]) }
            if let slot = next.statics[name] { return slot.value }
            if let methods = next.staticMethods[name] { return .function(OverloadSet(name: name, candidates: methods)) }
        }
        return nil
    }

    /// `obj.move(by: 1)`: the method the instance's own class (or the nearest above it) gives.
    func callClassMethod(_ instance: ClassInstance, _ name: String, _ arguments: [Argument], overload: Int?) throws -> Value? {
        let methods = instance.type.allMethods(name)
        guard !methods.isEmpty else { return nil }
        let values = try arguments.map { argument -> Argument in
            if case .caseLiteral = argument.value { return argument }
            return Argument(label: argument.label, value: .literal(try evaluate(argument.value)))
        }
        let set = narrowed(OverloadSet(name: name, candidates: methods), overload)
        let (method, bindings) = try resolve(set) { try self.bind(values, to: $0) }
        return try invoke(method, with: bindings, receiver: Receiver(.object(instance), mutable: true))
    }

    /// `super.name(…)`: the method the class above the one whose body this is gives, on the same instance.
    func callSuperMethod(_ name: String, _ arguments: [Argument], overload: Int?) throws -> Value {
        guard let owner = task.owners.last, let parent = owner.superclass else { throw RuntimeError("'super' needs a superclass") }
        guard case .object(let instance as ClassInstance)? = lookup("self")?.value else { throw RuntimeError("'super' is only in a method") }
        if name == "init" {
            try delegateInitializer(of: instance, in: parent, arguments, isSuper: true)
            return .nothing
        }
        let methods = parent.allMethods(name)
        guard !methods.isEmpty else { throw RuntimeError("\(parent.name) has no method '\(name)'") }
        let values = try arguments.map { Argument(label: $0.label, value: .literal(try evaluate($0.value))) }
        let (method, bindings) = try resolve(narrowed(OverloadSet(name: name, candidates: methods), overload)) { try self.bind(values, to: $0) }
        return try invoke(method, with: bindings, receiver: Receiver(.object(instance), mutable: true))
    }

    /// `super.name`: a property of the class above.
    func superProperty(_ name: String) throws -> Value {
        guard let owner = task.owners.last, let parent = owner.superclass else { throw RuntimeError("'super' needs a superclass") }
        guard case .object(let instance as ClassInstance)? = lookup("self")?.value else { throw RuntimeError("'super' is only in a method") }
        if let stored = instance.storage[name] { return read(stored) }
        if let getter = parent.computedProperty(name) { return try invoke(getter, with: [:], receiver: Receiver(.object(instance), mutable: true)) }
        throw RuntimeError("\(parent.name) has no property '\(name)'")
    }

    // MARK: Assigning

    /// `obj.name = value` (or a change deeper in it): in place, since every holder sees it.
    func updatedInstance(
        _ instance: ClassInstance, _ name: String, rest: ArraySlice<Assignment.Step>, initializing: Bool,
        _ change: (Value, TypeAnnotation?) throws -> Value, deeper: (Value, ArraySlice<Assignment.Step>, TypeAnnotation?) throws -> Value
    ) throws {
        if let setter = instance.type.setter(name), rest.isEmpty {
            let current = try classMember(name, of: instance) ?? .nothing
            let newValue = try change(current, instance.type.computedProperty(name)?.returnType)
            let parameter = setter.parameters[0]
            _ = try invoke(setter, with: [parameter.name: try checked(newValue, for: parameter, of: name)], receiver: Receiver(.object(instance), mutable: true))
            return
        }
        guard let property = instance.type.property(name) else {
            let what = instance.type.computedProperty(name) != nil ? "it's a computed property" : "\(instance.type.name) has no property '\(name)'"
            throw RuntimeError("cannot assign to '\(name)': \(what)")
        }
        guard property.mutable || initializing else { throw RuntimeError("cannot assign to '\(name)': it's a 'let' property of \(instance.type.name)") }
        let current = read(instance.storage[name] ?? .nothing)
        let value = rest.isEmpty ? try change(current, property.type) : try deeper(current, rest, property.type)
        var stored = value
        if let expected = property.type {
            guard let conforming = conform(value, to: expected) else {
                throw RuntimeError("\(instance.type.name).\(name) must be \(expected), not \(value.typeName)")
            }
            stored = conforming
        }
        if let observers = instance.type.observer(name), !initializing {
            let receiver = Receiver(.object(instance), mutable: true)
            if let willSet = observers.willSet { _ = try invoke(willSet, with: [willSet.parameters[0].name: stored], receiver: receiver) }
            let old = instance.storage[name] ?? .nothing
            instance.storage[name] = wrapped(stored, property)
            if let didSet = observers.didSet { _ = try invoke(didSet, with: [didSet.parameters[0].name: read(old)], receiver: receiver) }
            return
        }
        instance.storage[name] = wrapped(stored, property)
    }
}
