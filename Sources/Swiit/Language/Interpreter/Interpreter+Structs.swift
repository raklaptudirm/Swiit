import Foundation
import SwishKit

/// A struct's definition. Its values are records with its name as their
/// type, so they're values like Swift's structs, and tables, `where`,
/// `select` and `to json` work on them as on any record; what the type adds
/// (computed properties, methods, initializers) is looked up through here.
@_spi(Shell) public final class StructType: SwishObject, @unchecked Sendable {
    @_spi(Shell) public let name: String
    /// Stored properties, in declaration order: the order of a value's fields.
    @_spi(Shell) public let stored: [PropertyDecl]
    @_spi(Shell) public let computed: [String: Function]
    @_spi(Shell) public let methods: [String: OverloadSet]
    /// Custom initializers; without any, the memberwise one.
    @_spi(Shell) public let initializers: OverloadSet?
    @_spi(Shell) public let memberwise: Function
    /// The protocols it declares: `struct Point: Equatable`.
    @_spi(Shell) public let conformances: [String]
    /// `static let` and `static var`: declared, with their types once checked;
    /// the stored ones' values are in `statics`.
    @_spi(Shell) public let staticProperties: [PropertyDecl]
    @_spi(Shell) public let staticComputed: [String: Function]
    @_spi(Shell) public let staticMethods: [String: OverloadSet]
    @_spi(Shell) public var statics: [String: StaticValue] = [:]

    /// A stored static property's value, kept on the type.
    @_spi(Shell) public final class StaticValue {
        @_spi(Shell) public var value: Value
        @_spi(Shell) public let mutable: Bool

        @_spi(Shell) public init(_ value: Value, mutable: Bool) {
            self.value = value
            self.mutable = mutable
        }
    }

    @_spi(Shell) public init(name: String, stored: [PropertyDecl], computed: [String: Function], methods: [String: OverloadSet],
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

    @_spi(Shell) public func property(_ name: String) -> PropertyDecl? {
        stored.first { $0.name == name }
    }

    @_spi(Shell) public func staticProperty(_ name: String) -> PropertyDecl? {
        staticProperties.first { $0.name == name }
    }

    @_spi(Shell) public var typeName: String { "struct" }
    @_spi(Shell) public var memberNames: [String] { [] }
    @_spi(Shell) public func member(_ name: String) -> Value? { nil }
    @_spi(Shell) public var fields: Record? { nil }
    @_spi(Shell) public var description: String { "struct \(name)" }
}

/// `self` for a method: its value going in, and as the method left it.
@_spi(Shell) public final class Receiver {
    @_spi(Shell) public var value: Value
    @_spi(Shell) public let mutable: Bool
    /// In an `init`, which may also set `let` properties.
    @_spi(Shell) public let initializing: Bool

    @_spi(Shell) public init(_ value: Value, mutable: Bool, initializing: Bool = false) {
        self.value = value
        self.mutable = mutable
        self.initializing = initializing
    }
}

extension Interpreter {
    // MARK: Declaring

    /// `natives`: Swift bodies for the methods the prelude declares without
    /// one, by `Type.method`.
    @_spi(Shell) public func declare(_ decl: StructDecl, natives: [String: FunctionBody] = [:]) throws {
        var computed: [String: Function] = [:]
        for property in decl.properties {
            guard let getter = property.getter else { continue }
            computed[property.name] = Function(
                name: property.name, parameters: [], returnType: property.type, body: .swish(getter),
                captured: captureScopes(property.getterNames)
            )
        }
        var methods: [String: [Function]] = [:]
        for method in decl.methods {
            methods[method.name, default: []].append(Function(
                name: method.name, parameters: method.parameters, returnType: method.returnType,
                body: natives["\(decl.name).\(method.name)"] ?? .swish(method.body), captured: captureScopes(method.names),
                documentation: method.documentation,
                isMutating: method.isMutating, isThrowing: method.isThrowing
            ))
        }
        let initializers = decl.initializers.map { initializer in
            Function(
                name: "\(decl.name).init", parameters: initializer.parameters, returnType: nil,
                body: .swish(initializer.body), captured: captureScopes(initializer.names), documentation: initializer.documentation,
                isMutating: true, isThrowing: initializer.isThrowing
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
            returnType: nil, body: .native { _, _ in .nothing }
        )
        var staticComputed: [String: Function] = [:]
        for property in decl.staticProperties {
            guard let getter = property.getter else { continue }
            staticComputed[property.name] = Function(
                name: property.name, parameters: [], returnType: property.type, body: .swish(getter),
                captured: captureScopes(property.getterNames)
            )
        }
        var staticMethods: [String: [Function]] = [:]
        for method in decl.staticMethods {
            staticMethods[method.name, default: []].append(Function(
                name: method.name, parameters: method.parameters, returnType: method.returnType,
                body: .swish(method.body), captured: captureScopes(method.names), documentation: method.documentation,
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

    @_spi(Shell) public func structType(named name: String) -> StructType? {
        guard case .object(let type as StructType)? = lookup(name)?.value else { return nil }
        return type
    }

    @_spi(Shell) public func structType(of record: Record) -> StructType? {
        record.typeName.flatMap(structType(named:))
    }

    // MARK: Making values

    /// `Point(x: 1, y: 2)`: through an `init` the struct declares, or the
    /// memberwise one.
    @_spi(Shell) public func construct(_ type: StructType, _ arguments: [Argument], overload: Int? = nil) throws -> Value {
        let values = try arguments.map { argument -> Argument in
            if case .caseLiteral = argument.value { return argument }
            return Argument(label: argument.label, value: .literal(try evaluate(argument.value)))
        }
        guard let initializers = type.initializers else {
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
        _ = try invoke(initializer, with: bindings, receiver: receiver)
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

    private func checked(_ value: Value, as property: PropertyDecl, of type: StructType) throws -> Value {
        guard let expected = property.type else { return value }
        guard let conforming = conform(value, to: expected) else {
            throw RuntimeError("\(type.name).\(property.name) must be \(expected), not \(value.typeName)")
        }
        return conforming
    }

    // MARK: Members

    /// A computed property's value, or a method as a function value; nil if
    /// the type has neither by that name.
    @_spi(Shell) public func structMember(_ name: String, of record: Record, _ type: StructType) throws -> Value? {
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
                     }, documentation: method.documentation)
        }
        return .function(OverloadSet(name: name, candidates: bound))
    }

    /// `Point.origin`, `Point.count`, or a static method as a function value;
    /// nil if the type has no static member by that name.
    @_spi(Shell) public func staticMember(_ name: String, of type: StructType) throws -> Value? {
        if let getter = type.staticComputed[name] { return try invoke(getter, with: [:]) }
        if let slot = type.statics[name] { return slot.value }
        return type.staticMethods[name].map(Value.function)
    }

    /// `Point.make(1)`.
    @_spi(Shell) public func callStatic(_ methods: OverloadSet, _ arguments: [Argument]) throws -> Value {
        let values = try arguments.map { argument -> Argument in
            if case .caseLiteral = argument.value { return argument }
            return Argument(label: argument.label, value: .literal(try evaluate(argument.value)))
        }
        let (method, bindings) = try resolve(methods) { try self.bind(values, to: $0) }
        return try invoke(method, with: bindings)
    }

    /// `p.move(by: 1)`. A mutating method changes `p` itself, so `p` must
    /// be a `var` (or a part of one).
    @_spi(Shell) public func callMethod(_ methods: OverloadSet, of base: Value, at baseExpr: Expr, _ arguments: [Argument]) throws -> Value {
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
    @_spi(Shell) public func mutate(_ receiver: Expr, by method: String, _ change: (Value) throws -> Value) throws {
        guard let (root, path) = lvalue(receiver) else {
            throw RuntimeError("cannot use mutating method '\(method)' on a value that isn't in a variable")
        }
        try checkAssignable(root, what: "use mutating method '\(method)' on")
        try update(root, path) { current, _ in try change(current) }
    }

    /// `p`, `p.a`, `xs[0].b`: somewhere a value can be put back.
    private func lvalue(_ expr: Expr) -> (String, [Assignment.Step])? {
        switch expr {
        case .variable(let name):
            return (name, [])
        case .member(let base, let name):
            return lvalue(base).map { ($0.0, $0.1 + [.member(name)]) }
        case .index(let base, let index):
            return lvalue(base).map { ($0.0, $0.1 + [.index(index)]) }
        default:
            return nil
        }
    }

    // MARK: Assigning

    /// `x = v`, `p.x += 1`, `xs[0] = v`, `r["k"] = v`.
    @_spi(Shell) public func assign(_ assignment: Assignment) throws {
        // `Point.count += 1`: a static var, set through its type.
        if structType(named: assignment.root) == nil, !(lookup(assignment.root)?.value.isDynamicObject ?? false) {
            try checkAssignable(assignment.root, what: "assign to")
        }
        try update(assignment.root, assignment.path) { current, type in
            let value = try evaluate(assignment.value, expecting: type)
            guard let op = assignment.op else { return value }
            return try apply(op, current, value)
        }
    }

    private func checkAssignable(_ root: String, what: String) throws {
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
        case (.member(let name), .record(var record)):
            if let structType = structType(of: record) {
                guard let property = structType.property(name) else {
                    let what = structType.computed[name] != nil ? "it's a computed property" : "\(structType.name) has no property '\(name)'"
                    throw RuntimeError("cannot assign to '\(name)': \(what)")
                }
                guard property.mutable || (initializing && path.count == 1) else {
                    throw RuntimeError("cannot assign to '\(name)': it's a 'let' property of \(structType.name)")
                }
                let value = try updated(record[name] ?? .nothing, rest, type: property.type, change)
                record[name] = try checked(value, as: property, of: structType)
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
        case (.index(let indexExpr), .record(var record)):
            let key = try evaluate(indexExpr)
            guard case .string(let name) = key else { throw RuntimeError("a record is indexed by String, not \(key.typeName)") }
            if structType(of: record) != nil {
                return try updated(base, [.member(name)] + rest, type: type, initializing: initializing, change)
            }
            record[name] = try updated(record[name] ?? .nothing, rest, type: nil, change)
            return .record(record)
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
        case (.index, _):
            throw RuntimeError("cannot assign into \(base.typeName) by index")
        }
    }
}
