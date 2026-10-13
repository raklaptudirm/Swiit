import Foundation
import SwiitKit

extension TypeChecker {
    // MARK: Assignment

    func checkAssignment(_ assignment: inout Assignment) throws {
        guard let symbol = lookup(assignment.root) else { throw TypeError("no variable named '\(assignment.root)'") }
        var type: TypeAnnotation
        // `Point.count += 1`: a static var is assigned through its type.
        var start = 0
        if case .structType(let info) = symbol {
            guard case .member(let name)? = assignment.path.first, let property = info.staticProperty(name) else {
                throw TypeError("cannot assign to '\(assignment.root)': it isn't a variable")
            }
            guard property.mutable, property.getter == nil else {
                let why = property.getter != nil ? "it's a computed property" : "it's a 'let' constant"
                throw TypeError("cannot assign to '\(info.name).\(name)': \(why)")
            }
            type = property.type ?? .unknown
            start = 1
        } else {
            guard case .variable(let rootType, let mutable) = symbol else {
                throw TypeError("cannot assign to '\(assignment.root)': it isn't a variable")
            }
            // A class instance is a reference: a `let` of one still has its members assigned.
            let isReference: Bool = { if case .named(let name) = rootType, structInfo(named: name)?.isClass == true { true } else { false } }()
            guard mutable || dynamicType(of: rootType) != nil || (isReference && !assignment.path.isEmpty) else {
                if assignment.root == "self" {
                    throw TypeError("cannot assign to self here: it's only changed by a mutating method")
                }
                throw TypeError("cannot assign to '\(assignment.root)': it's a 'let' constant")
            }
            type = rootType
        }
        for index in assignment.path.indices.dropFirst(start) {
            let last = index == assignment.path.count - 1
            switch assignment.path[index] {
            case .member:
                if let dynamic = dynamicType(of: type) {
                    type = dynamic.write
                } else if case .member(let name) = assignment.path[index], case .named(let structName) = type, let info = structInfo(named: structName) {
                    if info.property(name) == nil, info.settable.contains(name), let computed = info.computed[name] {
                        type = computed
                        continue
                    }
                    if info.property(name) == nil, let ext = extensionInfo(forKey: structName), ext.settable.contains(name), let computed = ext.computed[name] {
                        type = computed
                        continue
                    }
                    guard let property = info.property(name) else {
                        let why = info.computed[name] != nil ? "it's a computed property" : "\(structName) has no property '\(name)'"
                        throw TypeError("cannot assign to '\(name)': \(why)")
                    }
                    let initializing = assignment.root == "self" && index == 0 && lookup("$initializing") != nil
                    guard property.mutable || (initializing && last) else {
                        throw TypeError("cannot assign to '\(name)': it's a 'let' property of \(structName)")
                    }
                    type = property.type ?? .unknown
                } else if case .member(let name) = assignment.path[index], case .tuple(let elements) = type {
                    guard let element = tupleElement(name, of: elements) else { throw TypeError("\(type) has no element '\(name)'") }
                    type = element
                } else if type == .unknown || type == .record || type == .any {
                    type = .unknown
                } else if case .member(let name) = assignment.path[index], let (bridgedType, bindings) = bridged(type),
                          bridgedType.members.contains(where: { $0.kind == .property && !$0.isStatic && $0.name == name }) {
                    // `p.extension = "md"`: a Swift property with a setter.
                    guard let setter = bridgedType.members.first(where: { $0.kind == .setter && $0.name == name }) else {
                        throw TypeError("cannot assign to '\(name)': it's a get-only property of \(type)")
                    }
                    type = substitute(setter.parameters[0].type, bindings)
                } else {
                    throw TypeError("cannot assign to '\(assignment.path[index])' of \(type)")
                }
            case .index(var indexExpr):
                switch type {
                case .named where dynamicType(of: type) != nil:
                    try expect(&indexExpr, .string, "\(type)'s member name")
                    type = dynamicType(of: type)!.write
                case .named(let structName) where structInfo(named: structName)?.subscripts.isEmpty == false:
                    var arguments = [Argument(value: indexExpr)]
                    let (result, settable) = try structSubscript(structInfo(named: structName)!, &arguments)
                    guard settable else { throw TypeError("cannot assign through \(structName)'s subscript: it's get-only") }
                    indexExpr = arguments[0].value
                    type = result
                case .list(let element):
                    try expect(&indexExpr, .int, "a list's index")
                    type = element
                case .dictionary(let key, let value):
                    try expect(&indexExpr, key, "the key")
                    // Assigning nil removes the entry.
                    type = last ? .optional(value) : value
                case .unknown, .record, .any:
                    _ = try typeOf(&indexExpr)
                    type = .unknown
                default:
                    throw TypeError("cannot assign into \(type) by index")
                }
                assignment.path[index] = .index(indexExpr)
            case .subscripted(var arguments):
                guard case .named(let structName) = type, let info = structInfo(named: structName) else {
                    throw TypeError("cannot assign into \(type) by several indexes")
                }
                let (result, settable) = try structSubscript(info, &arguments)
                guard settable else { throw TypeError("cannot assign through \(structName)'s subscript: it's get-only") }
                type = result
                assignment.path[index] = .subscripted(arguments)
            case .indexDefault(var key, var fallback):
                guard case .dictionary(let keyType, let valueType) = type else {
                    throw TypeError("'default:' goes with a dictionary's key, not \(type)'s index")
                }
                try expect(&key, keyType, "the key")
                try expect(&fallback, valueType, "the default")
                type = valueType
                assignment.path[index] = .indexDefault(key, fallback)
            }
        }
        if let op = assignment.op {
            let valueType = try typeOf(&assignment.value, expecting: type)
            // `a += b` through a `+=` the type defines.
            if case .named(let typeName) = type,
               (structInfo(named: typeName)?.staticMethods["\(op.rawValue)="] ?? extensionInfo(forKey: typeName)?.staticMethods["\(op.rawValue)="]) != nil {
                return
            }
            let result = try binaryType(op, type, valueType)
            guard fits(result, type) else { throw TypeError("'\(op.rawValue)=' would make \(type) a \(result)") }
        } else {
            try expect(&assignment.value, type, "the value assigned")
        }
    }
}
