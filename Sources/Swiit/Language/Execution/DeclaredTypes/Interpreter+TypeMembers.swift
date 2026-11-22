import Foundation

extension Interpreter {
    // MARK: Declaring members

    /// The initializers a declaration gives, named for its type.
    func initializerFunctions(
        of initializers: [FunctionDecl],
        in typeName: String,
        adopt: (Function) -> Function = { $0 }
    ) -> [Function] {
        initializers.map { initializer in
            adopt(
                Function(
                    name: "\(typeName).init",
                    parameters: initializer.parameters,
                    returnType: nil,
                    body: .swiit(initializer.body),
                    captured: captureScopes(initializer.names),
                    documentation: initializer.documentation,
                    isMutating: true,
                    isThrowing: initializer.isThrowing,
                    isFailable: initializer.isFailable,
                    isConvenience: initializer.isConvenience
                )
            )
        }
    }

    /// The getter of each computed property, by name.
    func computedProperties(
        of properties: [PropertyDecl],
        adopt: (Function) -> Function = { $0 }
    ) -> [String: Function] {
        var computed: [String: Function] = [:]
        for property in properties {
            guard let getter = property.getter else { continue }
            computed[property.name] = adopt(
                Function(
                    name: property.name,
                    parameters: [],
                    returnType: property.type,
                    body: .swiit(getter),
                    captured: captureScopes(property.getterNames)
                )
            )
        }
        return computed
    }

    /// The methods of a declaration, grouped by name into overloads. A struct's may be mutating; a
    /// class's, and the static methods of either, are not.
    func overloads(
        of methods: [FunctionDecl],
        honorsMutating: Bool = false,
        adopt: (Function) -> Function = { $0 },
        body: (FunctionDecl) -> FunctionBody
    ) -> [String: OverloadSet] {
        var grouped: [String: [Function]] = [:]
        for method in methods {
            grouped[method.name, default: []]
                .append(
                    adopt(
                        Function(
                            name: method.name,
                            parameters: method.parameters,
                            returnType: method.returnType,
                            body: body(method),
                            captured: captureScopes(method.names),
                            documentation: method.documentation,
                            attributes: method.attributes,
                            isMutating: honorsMutating && method.isMutating,
                            isThrowing: method.isThrowing,
                            effect: method.effect
                        )
                    )
                )
        }
        return grouped.mapValues { OverloadSet(name: $0[0].name!, candidates: $0) }
    }

    /// The getters and setters of the computed static properties, by name.
    func staticFunctions(
        of properties: [PropertyDecl],
        adopt: (Function) -> Function = { $0 }
    ) -> (getters: [String: Function], setters: [String: Function]) {
        var getters: [String: Function] = [:]
        var setters: [String: Function] = [:]
        for property in properties {
            guard let getter = property.getter else { continue }
            getters[property.name] = adopt(
                Function(
                    name: property.name,
                    parameters: [],
                    returnType: property.type,
                    body: .swiit(getter),
                    captured: captureScopes(property.getterNames)
                )
            )
            if let setter = property.setter {
                setters[property.name] = Function(
                    name: property.name,
                    parameters: [Parameter(name: property.setterName, type: property.type ?? .any)],
                    returnType: nil,
                    body: .swiit(setter),
                    captured: captureScopes(property.setterNames)
                )
            }
        }
        return (getters, setters)
    }

    func declareSubscripts(
        _ subscripts: [SubscriptDecl],
        in members: TypeMembers,
        adopt: (Function) -> Function = { $0 }
    ) {
        for declared in subscripts {
            members.subscriptGetters.append(
                adopt(
                    Function(
                        name: "subscript",
                        parameters: declared.parameters,
                        returnType: declared.returnType,
                        body: .swiit(declared.getter),
                        captured: captureScopes(declared.getterNames)
                    )
                )
            )
            members.subscriptSetters.append(
                declared.setter.map { setter in
                    adopt(
                        Function(
                            name: "subscript",
                            parameters: declared.parameters + [
                                Parameter(name: declared.setterName, type: declared.returnType)
                            ],
                            returnType: nil,
                            body: .swiit(setter),
                            captured: captureScopes(declared.setterNames),
                            isMutating: true
                        )
                    )
                }
            )
        }
    }

    /// Fills in the setters, and gives the observers (`willSet`, `didSet`), of stored properties.
    func declareSettersAndObservers(
        _ properties: [PropertyDecl],
        in members: TypeMembers,
        adopt: (Function) -> Function = { $0 }
    ) -> [String: (willSet: Function?, didSet: Function?)] {
        var observers: [String: (willSet: Function?, didSet: Function?)] = [:]
        for property in properties {
            if let setter = property.setter {
                members.setters[property.name] = adopt(
                    Function(
                        name: property.name,
                        parameters: [
                            Parameter(name: property.setterName, type: property.type ?? .any)
                        ],
                        returnType: nil,
                        body: .swiit(setter),
                        captured: captureScopes(property.setterNames),
                        isMutating: true
                    )
                )
            }

            guard property.willSet != nil || property.didSet != nil else { continue }
            func observer(_ body: Program?, _ parameter: String, _ names: NamesUsed) -> Function? {
                body.map { body in
                    adopt(
                        Function(
                            name: property.name,
                            parameters: [Parameter(name: parameter, type: property.type ?? .any)],
                            returnType: nil,
                            body: .swiit(body),
                            captured: captureScopes(names),
                            isMutating: true
                        )
                    )
                }
            }
            observers[property.name] = (
                observer(property.willSet, property.willSetName, property.willSetNames),
                observer(property.didSet, property.didSetName, property.didSetNames)
            )
        }
        return observers
    }

    /// Evaluates the stored static properties of a type that is already bound, so a static value
    /// can be made of the type itself.
    func evaluateStaticValues(
        _ properties: [PropertyDecl],
        in members: TypeMembers,
        named name: String
    ) throws {
        for property in properties where property.getter == nil {
            guard let expr = property.defaultValue else { continue }
            var value = try evaluate(expr, expecting: property.type)
            if let expected = property.type {
                guard let conforming = conform(value, to: expected) else {
                    throw RuntimeError(
                        "\(name).\(property.name) must be \(expected), not \(value.typeName)"
                    )
                }
                value = conforming
            }
            members.statics[property.name] = StructType.StaticValue(
                value,
                mutable: property.mutable
            )
        }
    }
}
