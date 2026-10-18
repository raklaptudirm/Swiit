import Foundation

/// What extensions add to a type: members, and the protocols it conforms to by them.
struct ExtensionLayer {
    var members = MemberSet()
    var conformances: [String] = []

    /// Adds what `other` adds, after this: methods of one name go on as further overloads.
    mutating func merge(_ other: ExtensionLayer) {
        members.merge(other.members)
        conformances += other.conformances
    }
}

extension TypeChecker {
    // MARK: Extensions

    /// What names a type extensions can add to: `Int`, `Array`, a struct's own name.
    func extensionKey(of type: TypeAnnotation) -> String? {
        switch type {
        case .int: "Int"
        case .double: "Double"
        case .string: "String"
        case .bool: "Bool"
        case .list: "Array"
        case .dictionary: "Dictionary"
        case .named(let name): name
        case .generic(let name, _): name
        default: nil
        }
    }

    /// The names a collection's members give its parts, bound to what `base` holds.
    func elementBindings(for base: TypeAnnotation) -> [String: TypeAnnotation] {
        switch base {
        case .list(let element): ["Element": element]
        case .dictionary(let key, let value): ["Key": key, "Value": value]
        case .generic(_, let arguments) where arguments.count == 1: ["Element": arguments[0]]
        default: [:]
        }
    }

    /// What extensions (in this program, and in what ran before) add to `type`.
    func extensionLayer(for type: TypeAnnotation) -> ExtensionLayer? {
        extensionKey(of: type).flatMap(extensionLayer(forKey:))
    }

    /// What extensions add to a type, and what the extensions of the protocols it conforms to give as defaults.
    func extensionLayer(forKey key: String) -> ExtensionLayer? {
        var info = ownExtensionLayer(forKey: key)
        let declared = (structInfo(named: key)?.conformances ?? enumInfo(named: key)?.conformances ?? []) + (info?.conformances ?? [])
        for proto in declared.flatMap(protocolClosure) where proto != key {
            guard let defaults = ownExtensionLayer(forKey: proto) else { continue }
            if var existing = info { existing.merge(defaults); info = existing } else { info = defaults }
        }
        // A subclass has what the extensions of its superclasses add, and the defaults of the protocols they conform to.
        if let parent = structInfo(named: key)?.superclass, parent != key, let inherited = extensionLayer(forKey: parent) {
            if var existing = info { existing.merge(inherited); info = existing } else { info = inherited }
        }
        return info
    }

    func ownExtensionLayer(forKey key: String) -> ExtensionLayer? {
        var info = localExtensions[key]
        if let members = interpreter.typeExtensions[key] {
            var runtime = ExtensionLayer()
            func signatures(_ sets: [String: OverloadSet]) -> [String: [Signature]] {
                sets.mapValues { set in
                    set.candidates.enumerated().map { index, method in
                        var signature = signature(method)
                        signature.index = index
                        return signature
                    }
                }
            }
            for (name, function) in members.computed {
                runtime.members.properties[name] = MemberProperty(type: function.returnType ?? .unknown, isSettable: members.setters[name] != nil, stored: nil)
            }
            runtime.members.methods = signatures(members.methods)
            for property in members.staticProperties { runtime.members.staticProperties[property.name] = MemberProperty(staticDeclaration: property) }
            runtime.members.staticMethods = signatures(members.staticMethods)
            runtime.conformances = members.conformances
            if var existing = info { existing.merge(runtime); info = existing } else { info = runtime }
        }
        return info
    }

    /// Notes what an extension adds, so what is checked before its body can use it.
    func registerExtension(_ decl: ExtensionDecl) {
        var info = ExtensionLayer()
        let members = decl.members
        func signatures(_ declared: [FunctionDecl]) -> [String: [Signature]] {
            var result: [String: [Signature]] = [:]
            for method in declared {
                var signature = Signature(name: method.name, parameters: method.parameters, returns: method.returnType ?? .void,
                                          isMutating: method.isMutating, isThrowing: method.isThrowing, effect: method.effect)
                signature.index = result[method.name]?.count ?? 0
                result[method.name, default: []].append(signature)
            }
            return result
        }
        for property in members.properties where property.getter != nil {
            info.members.properties[property.name] = MemberProperty(type: property.type ?? .unknown, isSettable: property.setter != nil, stored: nil)
        }
        info.members.methods = signatures(members.methods)
        for property in members.staticProperties { info.members.staticProperties[property.name] = MemberProperty(staticDeclaration: property) }
        info.members.staticMethods = signatures(members.staticMethods)
        info.conformances = decl.conformances
        info.members.initializers = members.initializers.map { initializer in
            Signature(name: "\(decl.typeName).init", parameters: initializer.parameters,
                      returns: initializer.isFailable ? .optional(.named(decl.typeName)) : .named(decl.typeName),
                      isMutating: true, isThrowing: initializer.isThrowing)
        }
        if var existing = localExtensions[decl.typeName] { existing.merge(info); localExtensions[decl.typeName] = existing }
        else { localExtensions[decl.typeName] = info }
    }

    /// The type `self` is in an extension of the type named `key`, with its parts not yet known.
    func selfType(ofExtensionOf key: String) throws -> TypeAnnotation {
        switch key {
        case "Int": return .int
        case "Double": return .double
        case "String": return .string
        case "Bool": return .bool
        case "Array": return .list(.unknown)
        case "Dictionary": return .dictionary(.unknown, .unknown)
        default:
            if structInfo(named: key) != nil || enumInfo(named: key) != nil || protocolInfo(named: key) != nil { return .named(key) }
            if Bridge.types[key] != nil { return .generic(key, [.unknown]) }
            throw TypeError("can't extend '\(key)': it isn't a type Swiit knows")
        }
    }

    /// `parameters` (a collection's `Element`) aren't known inside the extension: they fit anything.
    private func erasingParameters(_ declaration: FunctionDecl) -> FunctionDecl {
        var copy = declaration
        func erased(_ type: TypeAnnotation) -> TypeAnnotation { substitute(type, [:]) }
        for index in copy.parameters.indices { copy.parameters[index].type = erased(copy.parameters[index].type) }
        copy.returnType = copy.returnType.map(erased)
        return copy
    }

    func checkExtension(_ decl: inout ExtensionDecl) throws {
        let selfType = try selfType(ofExtensionOf: decl.typeName)
        var members = decl.members
        for index in members.properties.indices {
            let property = members.properties[index]
            guard let getter = property.getter else { continue }
            var function = FunctionDecl(name: property.name, parameters: [], returnType: property.type.map { substitute($0, [:]) }, body: getter)
            try checkFunction(&function, self: selfType)
            members.properties[index].getter = function.body
            if let body = property.setter {
                var setter = FunctionDecl(name: property.name, parameters: [Parameter(name: property.setterName, type: substitute(property.type ?? .unknown, [:]))],
                                          returnType: nil, body: body)
                try checkFunction(&setter, self: selfType, mutating: true)
                members.properties[index].setter = setter.body
            }
        }
        for index in members.methods.indices {
            var function = erasingParameters(members.methods[index])
            try checkFunction(&function, self: selfType, mutating: function.isMutating)
            members.methods[index].body = function.body
        }
        for index in members.staticProperties.indices {
            let property = members.staticProperties[index]
            if let getter = property.getter {
                var function = FunctionDecl(name: property.name, parameters: [], returnType: property.type, body: getter)
                try checkFunction(&function)
                members.staticProperties[index].getter = function.body
            } else if var value = property.defaultValue {
                if let type = property.type { try expect(&value, type, "\(decl.typeName).\(property.name)'s value") }
                else { members.staticProperties[index].type = try typeOf(&value) }
                members.staticProperties[index].defaultValue = value
            }
        }
        for index in members.staticMethods.indices {
            var function = members.staticMethods[index]
            try checkFunction(&function)
            members.staticMethods[index].body = function.body
        }
        for index in members.initializers.indices {
            var function = members.initializers[index]
            function.name = "init"
            try checkFunction(&function, self: selfType, initializing: true)
            members.initializers[index].body = function.body
        }
        decl.members = members
        for proto in decl.conformances { try checkConformance(of: decl.typeName, to: proto) }
    }

    /// Whether the type has a member by that name, for a bare name inside it to mean `self`'s.
    func hasMember(_ type: TypeAnnotation, named name: String) -> Bool {
        if describe(type)?.instanceMember(name) != nil { return true }
        if case .named = type { return false }
        if let (bridgedType, _) = bridged(type) { return bridgedType.members.contains { !$0.isStatic && $0.name == name } }
        return false
    }
}
