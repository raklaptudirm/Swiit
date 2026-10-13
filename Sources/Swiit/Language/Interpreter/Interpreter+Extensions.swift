import Foundation
import SwiitKit

/// What a type has beyond what it was declared with: an enum's computed
/// properties and methods, or what extensions add to any type.
final class TypeMembers {
    var computed: [String: Function] = [:]
    var setters: [String: Function] = [:]
    var methods: [String: OverloadSet] = [:]
    var staticComputed: [String: Function] = [:]
    var staticMethods: [String: OverloadSet] = [:]
    var statics: [String: StructType.StaticValue] = [:]
    var staticProperties: [PropertyDecl] = []
    var initializers: OverloadSet?
    var subscriptGetters: [Function] = []
    var subscriptSetters: [Function?] = []
    /// Protocols added by `extension T: P`.
    var conformances: [String] = []
}

extension Interpreter {
    /// Builds the functions of a type's declared members into `members`, adding to what is there.
    func fill(
        _ members: TypeMembers, of name: String, properties: [PropertyDecl], methods: [FunctionDecl], staticProperties: [PropertyDecl],
        staticMethods: [FunctionDecl], initializers: [FunctionDecl], subscripts: [SubscriptDecl]
    ) throws {
        members.staticProperties += staticProperties
        for property in properties {
            guard let getter = property.getter else { continue }
            members.computed[property.name] = Function(
                name: property.name, parameters: [], returnType: property.type, body: .swiit(getter),
                captured: captureScopes(property.getterNames)
            )
            if let setter = property.setter {
                members.setters[property.name] = Function(
                    name: property.name, parameters: [Parameter(name: property.setterName, type: property.type ?? .any)], returnType: nil,
                    body: .swiit(setter), captured: captureScopes(property.setterNames), isMutating: true
                )
            }
        }
        func add(_ functions: [Function], to table: inout [String: OverloadSet]) {
            for function in functions {
                let existing = table[function.name!]?.candidates ?? []
                table[function.name!] = OverloadSet(name: function.name!, candidates: existing + [function])
            }
        }
        add(methods.map { method in
            Function(name: method.name, parameters: method.parameters, returnType: method.returnType, body: .swiit(method.body),
                     captured: captureScopes(method.names), documentation: method.documentation,
                     isMutating: method.isMutating, isThrowing: method.isThrowing)
        }, to: &members.methods)
        for property in staticProperties {
            guard let getter = property.getter else { continue }
            members.staticComputed[property.name] = Function(
                name: property.name, parameters: [], returnType: property.type, body: .swiit(getter),
                captured: captureScopes(property.getterNames)
            )
        }
        add(staticMethods.map { method in
            Function(name: method.name, parameters: method.parameters, returnType: method.returnType, body: .swiit(method.body),
                     captured: captureScopes(method.names), documentation: method.documentation, isThrowing: method.isThrowing)
        }, to: &members.staticMethods)
        let made = initializers.map { initializer in
            Function(
                name: "\(name).init", parameters: initializer.parameters, returnType: nil, body: .swiit(initializer.body),
                captured: captureScopes(initializer.names), documentation: initializer.documentation,
                isMutating: true, isThrowing: initializer.isThrowing, isFailable: initializer.isFailable
            )
        }
        if !made.isEmpty { members.initializers = OverloadSet(name: "\(name).init", candidates: (members.initializers?.candidates ?? []) + made) }
        for declared in subscripts {
            members.subscriptGetters.append(Function(
                name: "subscript", parameters: declared.parameters, returnType: declared.returnType, body: .swiit(declared.getter),
                captured: captureScopes(declared.getterNames)
            ))
            members.subscriptSetters.append(declared.setter.map { setter in
                Function(
                    name: "subscript", parameters: declared.parameters + [Parameter(name: declared.setterName, type: declared.returnType)],
                    returnType: nil, body: .swiit(setter), captured: captureScopes(declared.setterNames), isMutating: true
                )
            })
        }
        // Static values, which may be of the type itself, which is declared by now.
        for property in staticProperties where property.getter == nil {
            guard let expr = property.defaultValue else { continue }
            var value = try evaluate(expr, expecting: property.type)
            if let expected = property.type {
                guard let conforming = conform(value, to: expected) else {
                    throw RuntimeError("\(name).\(property.name) must be \(expected), not \(value.typeName)")
                }
                value = conforming
            }
            members.statics[property.name] = StructType.StaticValue(value, mutable: property.mutable)
        }
    }

    /// `extension Int { … }`: members and protocols added to a type, by its name.
    func declare(_ decl: ExtensionDecl) throws {
        let members = typeExtensions[decl.typeName] ?? TypeMembers()
        typeExtensions[decl.typeName] = members
        members.conformances += decl.conformances
        let source = decl.members
        try fill(members, of: decl.typeName, properties: source.properties, methods: source.methods, staticProperties: source.staticProperties,
                 staticMethods: source.staticMethods, initializers: source.initializers, subscripts: source.subscripts)
    }

    /// What names a value's type: `Int`, a struct's own name, `Array`.
    func typeKey(of value: Value) -> String? {
        switch value {
        case .int: "Int"
        case .double: "Double"
        case .string: "String"
        case .bool: "Bool"
        case .list: "Array"
        case .dictionary: "Dictionary"
        case .record(let record): record.typeName
        case .enumValue(let enumValue): enumValue.type.name
        case .object(let box as SwiftValue): box.typeName
        default: nil
        }
    }

    /// The members extensions add to a value's type (and protocols it conforms to) with a method of that name.
    func extensionMethods(_ name: String, of value: Value) -> OverloadSet? {
        extensionChain(of: value).lazy.compactMap { $0.methods[name] }.first
    }

    /// A computed property an extension adds, or a method as a function value; nil if there isn't one.
    func extensionMember(_ name: String, of value: Value) throws -> Value? {
        for members in extensionChain(of: value) {
            if let found = try extensionMember(name, of: value, in: members) { return found }
        }
        return nil
    }

    private func extensionMember(_ name: String, of value: Value, in members: TypeMembers) throws -> Value? {
        if let getter = members.computed[name] {
            return try invoke(getter, with: [:], receiver: Receiver(value, mutable: false))
        }
        guard let methods = members.methods[name] else { return nil }
        let bound = methods.candidates.map { method in
            Function(name: method.name, parameters: method.parameters, returnType: method.returnType,
                     body: .native { interpreter, arguments in
                         guard !method.isMutating else {
                             throw RuntimeError("mutating method '\(name)' must be called on a variable, as in value.\(name)(…)")
                         }
                         return try interpreter.invoke(method, with: arguments, receiver: Receiver(value, mutable: false))
                     }, documentation: method.documentation, isMutating: method.isMutating)
        }
        return .function(OverloadSet(name: name, candidates: bound))
    }

    /// `P.zero`, `P.make`: what an extension adds to a type as static members.
    func extensionStaticMember(_ name: String, ofTypeNamed typeName: String) throws -> Value? {
        guard let members = typeExtensions[typeName] else { return nil }
        if let getter = members.staticComputed[name] { return try invoke(getter, with: [:]) }
        if let slot = members.statics[name] { return slot.value }
        return members.staticMethods[name].map(Value.function)
    }

    /// The protocols a type was declared with, and extensions gave it.
    func conformances(ofTypeNamed name: String, declared: [String]) -> [String] {
        declared + (typeExtensions[name]?.conformances ?? [])
    }
}
