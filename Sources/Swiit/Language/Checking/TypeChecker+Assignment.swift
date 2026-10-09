import Foundation
import SwishKit

extension TypeChecker {
    // MARK: Assignment

    @_spi(Shell) public func checkAssignment(_ assignment: inout Assignment) throws {
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
            guard mutable || dynamicType(of: rootType) != nil else {
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
            }
        }
        if let op = assignment.op {
            let valueType = try typeOf(&assignment.value, expecting: type)
            let result = try binaryType(op, type, valueType)
            guard fits(result, type) else { throw TypeError("'\(op.rawValue)=' would make \(type) a \(result)") }
        } else {
            try expect(&assignment.value, type, "the value assigned")
        }
    }
}
