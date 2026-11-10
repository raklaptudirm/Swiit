import Foundation

// Checking struct declarations: their properties, initializers, methods and conformances.

extension TypeChecker {
    func structInfo(_ decl: StructDecl) throws -> TypeProfile {
        var methods: [String: [Signature]] = [:]
        for method in decl.methods {
            var signature = Signature(
                name: method.name,
                parameters: method.parameters,
                returns: method.returnType ?? .void,
                isMutating: method.isMutating,
                isThrowing: method.isThrowing
            )
            signature.thrownType = method.thrownType
            signature.attributes = method.attributes
            signature.documentation = method.documentation
            signature.index = methods[method.name]?.count ?? 0
            methods[method.name, default: []].append(signature)
        }
        var stored: [PropertyDecl] = []
        for var property in decl.properties where property.getter == nil {
            // An untyped property takes its default's type.
            if property.type == nil, var defaultValue = property.defaultValue {
                // A lazy one may use `self`, which isn't there yet: its type is found when the body
                // is checked.
                property.type =
                    property.isLazy
                    ? ((try? typeOf(&defaultValue)) ?? .unknown) : try typeOf(&defaultValue)
            }
            stored.append(property)
        }
        let memberwise = Signature(
            name: decl.name,
            parameters: stored.filter { $0.mutable || $0.defaultValue == nil }
                .map {
                    Parameter(
                        label: $0.name,
                        name: $0.name,
                        type: $0.type ?? .unknown,
                        defaultValue: $0.defaultValue
                    )
                },
            returns: .named(decl.name)
        )
        let initializers = decl.initializers.enumerated()
            .map { index, initializer in
                Signature(
                    name: "\(decl.name).init",
                    parameters: initializer.parameters,
                    returns: initializer.isFailable
                        ? .optional(.named(decl.name)) : .named(decl.name),
                    isMutating: true,
                    isThrowing: initializer.isThrowing,
                    index: index
                )
            }
        // An untyped static takes its value's type once the struct is known
        // (`checkStruct`), since the value may use the struct itself.
        var staticMethods: [String: [Signature]] = [:]
        for method in decl.staticMethods {
            var signature = Signature(
                name: method.name,
                parameters: method.parameters,
                returns: method.returnType ?? .void,
                isThrowing: method.isThrowing
            )
            signature.index = staticMethods[method.name]?.count ?? 0
            staticMethods[method.name, default: []].append(signature)
        }
        var profile = TypeProfile(name: decl.name, kind: .structure)
        profile.conformances = decl.conformances
        profile.isDynamicMemberLookup = decl.isDynamicMemberLookup
        profile.memberwise = memberwise
        for property in decl.properties where property.getter != nil {
            profile.declared.properties[property.name] = MemberProperty(
                type: property.type ?? .unknown,
                isSettable: property.setter != nil,
                stored: nil
            )
        }
        for property in stored {
            profile.declared.properties[property.name] = MemberProperty(
                type: property.type ?? .unknown,
                isSettable: property.mutable,
                stored: property
            )
        }
        profile.declared.methods = methods
        profile.declared.initializers = initializers
        for property in decl.staticProperties {
            profile.declared.staticProperties[property.name] = MemberProperty(
                staticDeclaration: property
            )
        }
        profile.declared.staticMethods = staticMethods
        for (index, declared) in decl.subscripts.enumerated() {
            profile.subscripts.append(
                Signature(
                    name: "subscript",
                    parameters: declared.parameters,
                    returns: declared.returnType,
                    index: index
                )
            )
            profile.subscriptSettable.append(declared.setter != nil)
        }
        return profile
    }

    func checkStruct(_ decl: inout StructDecl, isClass: Bool = false) throws {
        let selfType = TypeAnnotation.named(decl.name)
        // Equatable, Hashable and Encodable come from the fields, which must
        // have them too; Comparable would need a `<` of its own.
        for proto in decl.conformances {
            // A protocol of the program's asks what it says.
            if protocolInfo(named: proto) != nil {
                try checkConformance(of: decl.name, to: proto)
                continue
            }
            // What a class conforms to by saying so isn't made from its fields.
            if isClass { continue }
            if proto == "Comparable", !decl.staticMethods.contains(where: { $0.name == "<" }) {
                throw TypeError(
                    "\(decl.name) can't be Comparable without a '<' of its own: static func < (a: \(decl.name), b: \(decl.name)) -> Bool"
                )
            }
            // Iterating needs a `makeIterator` of its own, which nothing declared in Swiit has yet.
            if proto == "Sequence" { throw TypeError("\(decl.name) can't be a Sequence yet") }
            guard !TypeChecker.askNothingOfMembers.contains(proto) else { continue }
            for property in decl.properties where property.getter == nil {
                if let type = property.type, !conforms(type, to: proto) {
                    throw TypeError(
                        "\(decl.name) can't be \(proto): its '\(property.name)' is \(type), which isn't"
                    )
                }
            }
        }
        for index in decl.properties.indices {
            let property = decl.properties[index]
            // Observers see the property's value, and may change the rest of the struct.
            if property.getter == nil {
                for (observer, name) in [
                    (property.willSet, property.willSetName),
                    (property.didSet, property.didSetName),
                ] {
                    guard let body = observer else { continue }
                    var function = FunctionDecl(
                        name: property.name,
                        parameters: [Parameter(name: name, type: property.type ?? .unknown)],
                        returnType: nil,
                        body: body
                    )
                    try checkFunction(&function, self: selfType, mutating: true)
                    if body == property.willSet && name == property.willSetName {
                        decl.properties[index].willSet = function.body
                    } else {
                        decl.properties[index].didSet = function.body
                    }
                }
            }
            if let getter = property.getter {
                var function = FunctionDecl(
                    name: property.name,
                    parameters: [],
                    returnType: property.type,
                    body: getter
                )
                try checkFunction(&function, self: selfType)
                decl.properties[index].getter = function.body
                if let setter = property.setter {
                    var function = FunctionDecl(
                        name: property.name,
                        parameters: [
                            Parameter(name: property.setterName, type: property.type ?? .unknown)
                        ],
                        returnType: nil,
                        body: setter
                    )
                    try checkFunction(&function, self: selfType, mutating: true)
                    decl.properties[index].setter = function.body
                }
            } else if property.defaultValue != nil, let type = property.type {
                // A lazy one is worked out with `self`.
                if property.isLazy { scopes.append(["self": .variable(selfType, mutable: true)]) }
                defer { if property.isLazy { scopes.removeLast() } }
                try expect(
                    &decl.properties[index].defaultValue!,
                    type,
                    "\(decl.name).\(property.name)'s default"
                )
            }
        }
        for index in decl.methods.indices {
            try checkFunction(
                &decl.methods[index],
                self: selfType,
                mutating: isClass || decl.methods[index].isMutating
            )
        }
        for index in decl.subscripts.indices {
            let declared = decl.subscripts[index]
            var getter = FunctionDecl(
                name: "subscript",
                parameters: declared.parameters,
                returnType: declared.returnType,
                body: declared.getter
            )
            try checkFunction(&getter, self: selfType)
            decl.subscripts[index].getter = getter.body
            if let body = declared.setter {
                var setter = FunctionDecl(
                    name: "subscript",
                    parameters: declared.parameters + [
                        Parameter(name: declared.setterName, type: declared.returnType)
                    ],
                    returnType: nil,
                    body: body
                )
                try checkFunction(&setter, self: selfType, mutating: true)
                decl.subscripts[index].setter = setter.body
            }
        }
        for index in decl.staticProperties.indices {
            let property = decl.staticProperties[index]
            if let getter = property.getter {
                var function = FunctionDecl(
                    name: property.name,
                    parameters: [],
                    returnType: property.type,
                    body: getter
                )
                try checkFunction(&function)
                decl.staticProperties[index].getter = function.body
            } else if var value = property.defaultValue {
                if let type = property.type {
                    try expect(&value, type, "\(decl.name).\(property.name)'s value")
                } else {
                    // Its type is its value's, which the struct's other
                    // checks can now use.
                    decl.staticProperties[index].type = try typeOf(&value)
                    if case .structType(var info)? = scopes[scopes.count - 1][decl.name] {
                        info.declared.staticProperties[property.name] = MemberProperty(
                            staticDeclaration: decl.staticProperties[index]
                        )
                        scopes[scopes.count - 1][decl.name] = .structType(info)
                    }
                }
                decl.staticProperties[index].defaultValue = value
            }
        }
        for index in decl.staticMethods.indices {
            try checkFunction(&decl.staticMethods[index])
        }
        for index in decl.initializers.indices {
            var function = decl.initializers[index]
            function.name = "\(decl.name).init"
            try checkFunction(&function, self: selfType, initializing: true)
            function.name = "init"
            decl.initializers[index] = function
        }
    }

    /// Protocols a type conforms to by saying so, whatever its members are:
    /// it describes itself, or can be thrown.
    static let askNothingOfMembers: Set<String> = Set([
        "CustomStringConvertible", "Error", "CaseIterable", "Sendable", "Decodable", "Codable",
        "AnyObject",
    ])
    .union(looseProtocols)

    /// Swift's protocols that Swiit takes on trust: a type that says it has one is believed, and a
    /// generic asking for one is given any type.
    static let looseProtocols: Set<String> = [
        "Collection", "BidirectionalCollection", "RandomAccessCollection", "MutableCollection",
        "RangeReplaceableCollection",
        "Numeric", "SignedNumeric", "BinaryInteger", "FixedWidthInteger", "SignedInteger",
        "UnsignedInteger",
        "FloatingPoint",
        "BinaryFloatingPoint", "IteratorProtocol", "LosslessStringConvertible", "Identifiable",
        "ExpressibleByArrayLiteral", "ExpressibleByStringLiteral", "ExpressibleByIntegerLiteral",
    ]
}
