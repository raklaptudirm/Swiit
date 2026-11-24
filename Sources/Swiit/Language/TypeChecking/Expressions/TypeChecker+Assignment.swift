import Foundation

extension TypeChecker {
    // MARK: Assignment

    func checkAssignment(_ assignment: inout Assignment) throws {
        var (type, start) = try assignmentRoot(assignment)
        for index in assignment.path.indices.dropFirst(start) {
            type = try assignmentStep(&assignment, at: index, from: type)
        }
        try checkAssignedValue(&assignment, to: type)
    }

    /// The type of what an assignment's root names, and how many path steps the root consumed.
    private func assignmentRoot(_ assignment: Assignment) throws -> (TypeExpression, Int) {
        guard let symbol = lookup(assignment.root) else {
            throw TypeError("no variable named '\(assignment.root)'")
        }

        // `Point.count += 1`: a static var is assigned through its type.
        if case .structType(let info) = symbol {
            guard case .member(let name)? = assignment.path.first,
                let property = info.declared.staticProperties[name]
            else {
                throw TypeError("cannot assign to '\(assignment.root)': it isn't a variable")
            }
            guard property.isSettable else {
                let why =
                    property.stored?.getter != nil
                    ? "it's a computed property" : "it's a 'let' constant"
                throw TypeError("cannot assign to '\(info.name).\(name)': \(why)")
            }
            return (property.type, 1)
        }

        guard case .variable(let rootType, let mutable) = symbol else {
            throw TypeError("cannot assign to '\(assignment.root)': it isn't a variable")
        }

        // A class instance is a reference: a `let` of one still has its members assigned.
        let isReference: Bool = {
            if let name = rootType.plainName, structInfo(named: name)?.isClass == true {
                true
            } else {
                false
            }
        }()
        guard mutable || (isReference && !assignment.path.isEmpty) else {
            if assignment.root == "self" {
                throw TypeError(
                    "cannot assign to self here: it's only changed by a mutating method"
                )
            }
            throw TypeError("cannot assign to '\(assignment.root)': it's a 'let' constant")
        }
        return (rootType, 0)
    }

    /// The type left after one step of an assignment's path, checking that the step can be written.
    private func assignmentStep(
        _ assignment: inout Assignment,
        at index: Int,
        from type: TypeExpression
    ) throws -> TypeExpression {
        switch assignment.path[index] {
        case .member(let name):
            return try assignedMember(name, of: type, in: &assignment, at: index)

        case .index(var indexExpr):
            let result = try assignedIndex(
                &indexExpr,
                of: type,
                isLast: index == assignment.path.count - 1
            )
            assignment.path[index] = .index(indexExpr)
            return result

        case .subscripted(var arguments):
            guard let structName = type.plainName, let info = structInfo(named: structName)
            else {
                throw TypeError("cannot assign into \(type) by several indexes")
            }
            let (result, settable) = try structSubscript(info, &arguments)
            guard settable else {
                throw TypeError("cannot assign through \(structName)'s subscript: it's get-only")
            }
            assignment.path[index] = .subscripted(arguments)
            return result

        case .optionalChain:
            guard let wrapped = type.optionalWrapped else {
                throw TypeError("'?' needs an optional, not \(type)")
            }
            return wrapped

        case .unwrap:
            // A dictionary's entry is written as the value, but read as an optional:
            // `d[k]![0] = 1`.
            if let wrapped = type.optionalWrapped {
                return wrapped
            }
            guard index > 0, case .index = assignment.path[index - 1] else {
                throw TypeError("'!' needs an optional, not \(type)")
            }
            return type

        case .indexDefault(var key, var fallback):
            guard let (keyType, valueType) = type.dictionaryTypes else {
                throw TypeError("'default:' goes with a dictionary's key, not \(type)'s index")
            }
            try expect(&key, keyType, "the key")
            try expect(&fallback, valueType, "the default")
            assignment.path[index] = .indexDefault(key, fallback)
            return valueType
        }
    }

    /// The type of `type.name` as the target of an assignment.
    private func assignedMember(
        _ name: String,
        of type: TypeExpression,
        in assignment: inout Assignment,
        at index: Int
    ) throws -> TypeExpression {
        if let structName = type.plainName,
            let description = describe(type),
            [.structure, .class, .actor].contains(description.kind)
        {
            // `@dynamicMemberLookup`: `x.name = v` is `x[dynamicMember: "name"] = v`.
            if let info = structInfo(named: structName), info.isDynamicMemberLookup,
                description.instanceMember(name) == nil
            {
                var arguments = [
                    Argument(label: "dynamicMember", value: .literal(.string(name)))
                ]
                let (result, settable) = try structSubscript(info, &arguments)
                guard settable else {
                    throw TypeError(
                        "cannot assign to '\(name)': \(structName)'s dynamic members are get-only"
                    )
                }
                assignment.path[index] = .subscripted(arguments)
                return result
            }

            guard case .property(let property)? = description.instanceMember(name) else {
                throw TypeError(
                    "cannot assign to '\(name)': \(structName) has no property '\(name)'"
                )
            }

            // A computed property is assigned through its setter.
            guard let stored = property.stored else {
                guard property.isSettable else {
                    throw TypeError("cannot assign to '\(name)': it's a computed property")
                }
                return property.type
            }
            let initializing =
                assignment.root == "self" && index == 0
                && lookup(InternalName.initializing) != nil
            let last = index == assignment.path.count - 1
            guard stored.mutable || (initializing && last) else {
                throw TypeError(
                    "cannot assign to '\(name)': it's a 'let' property of \(structName)"
                )
            }
            return property.type
        }

        if case .tuple(let tuple) = type {
            guard let element = tupleElement(name, of: tuple.elements) else {
                throw TypeError("\(type) has no element '\(name)'")
            }
            return element
        }

        if type == .unknown || type == .record || type == .any {
            return .unknown
        }

        guard let (bridgedType, bindings) = bridged(type),
            bridgedType.lowered.contains(where: {
                $0.kind == .property && !$0.isStatic && $0.name == name
            })
        else {
            throw TypeError("cannot assign to '\(assignment.path[index])' of \(type)")
        }

        // `p.extension = "md"`: a Swift property with a setter.
        guard
            let setter = bridgedType.lowered.first(where: {
                $0.kind == .setter && $0.name == name
            })
        else {
            throw TypeError("cannot assign to '\(name)': it's a get-only property of \(type)")
        }
        return substitute(setter.parameters[0].type, bindings)
    }

    /// The type of `type[index]` as the target of an assignment.
    private func assignedIndex(
        _ indexExpr: inout Expr,
        of type: TypeExpression,
        isLast last: Bool
    ) throws -> TypeExpression {
        if let structName = type.plainName,
            let info = structInfo(named: structName), !info.subscripts.isEmpty
        {
            var arguments = [Argument(value: indexExpr)]
            let (result, settable) = try structSubscript(info, &arguments)
            guard settable else {
                throw TypeError("cannot assign through \(structName)'s subscript: it's get-only")
            }
            indexExpr = arguments[0].value
            return result
        }
        if let element = type.arrayElement {
            try expect(&indexExpr, .int, "a list's index")
            return element
        }
        if let (key, value) = type.dictionaryTypes {
            try expect(&indexExpr, key, "the key")
            // Assigning nil removes the entry.
            return last ? .optional(value) : value
        }
        if type == .unknown || type == .record || type == .any {
            _ = try typeOf(&indexExpr)
            return .unknown
        }
        throw TypeError("cannot assign into \(type) by index")
    }

    /// Checks the value an assignment stores against the type of its target.
    private func checkAssignedValue(_ assignment: inout Assignment, to type: TypeExpression) throws
    {
        guard let op = assignment.op else {
            try expect(&assignment.value, type, "the value assigned")
            return
        }

        let valueType = try typeOf(&assignment.value, expecting: type)

        // `a += b` through a `+=` the type defines.
        if let typeName = type.plainName,
            describe(named: typeName)?.staticMethods(named: "\(op.rawValue)=").isEmpty == false
        {
            return
        }

        let result = try binaryType(op, type, valueType)
        guard fits(result, type) else {
            throw TypeError("'\(op.rawValue)=' would make \(type) a \(result)")
        }
    }
}
