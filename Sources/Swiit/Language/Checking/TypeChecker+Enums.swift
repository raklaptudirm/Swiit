import Foundation

// Checking enum declarations: their cases, raw values and members.

extension TypeChecker {
    func enumInfo(_ decl: EnumDecl) -> TypeProfile {
        func signatures(_ declared: [FunctionDecl]) -> [String: [Signature]] {
            var result: [String: [Signature]] = [:]
            for method in declared {
                var signature = Signature(
                    name: method.name,
                    parameters: method.parameters,
                    returns: method.returnType ?? .void,
                    isMutating: method.isMutating,
                    isThrowing: method.isThrowing
                )
                signature.index = result[method.name]?.count ?? 0
                result[method.name, default: []].append(signature)
            }
            return result
        }
        var profile = TypeProfile(name: decl.name, kind: .enumeration)
        profile.cases = decl.cases.map { ($0.name, $0.associated) }
        profile.rawType = decl.rawType
        profile.conformances = decl.conformances
        profile.typeParameters = decl.typeParameters
        for property in decl.properties where property.getter != nil {
            profile.declared.properties[property.name] = MemberProperty(
                type: property.type ?? .unknown,
                isSettable: false,
                stored: nil
            )
        }
        profile.declared.methods = signatures(decl.methods)
        for property in decl.staticProperties {
            profile.declared.staticProperties[property.name] = MemberProperty(
                staticDeclaration: property
            )
        }
        profile.declared.staticMethods = signatures(decl.staticMethods)
        profile.declared.initializers = decl.initializers.enumerated()
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
        profile.addSynthesizedEnumMembers()
        return profile
    }

    func checkEnum(_ decl: inout EnumDecl) throws {
        for proto in decl.conformances where !TypeChecker.askNothingOfMembers.contains(proto) {
            if protocolInfo(named: proto) != nil {
                try checkConformance(of: decl.name, to: proto); continue
            }
            // Iterating needs a `makeIterator` of its own, which nothing declared in Swiit has yet.
            if proto == "Sequence" { throw TypeError("\(decl.name) can't be a Sequence yet") }
            for enumCase in decl.cases {
                for value in enumCase.associated where !conforms(value.type, to: proto) {
                    throw TypeError(
                        "\(decl.name) can't be \(proto): \(decl.name).\(enumCase.name) holds a \(value.type), which isn't"
                    )
                }
            }
        }
        if let rawType = decl.rawType {
            for index in decl.cases.indices where decl.cases[index].rawValue != nil {
                try expect(
                    &decl.cases[index].rawValue!,
                    rawType,
                    "\(decl.name).\(decl.cases[index].name)'s raw value"
                )
            }
        }
        // Its members, with the case as `self`.
        let selfType = TypeAnnotation.named(decl.name)
        for index in decl.properties.indices {
            let property = decl.properties[index]
            guard let getter = property.getter else { continue }
            var function = FunctionDecl(
                name: property.name,
                parameters: [],
                returnType: property.type,
                body: getter
            )
            try checkFunction(&function, self: selfType)
            decl.properties[index].getter = function.body
        }
        for index in decl.methods.indices {
            try checkFunction(
                &decl.methods[index],
                self: selfType,
                mutating: decl.methods[index].isMutating
            )
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
                    decl.staticProperties[index].type = try typeOf(&value)
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
}
