import Foundation
import SwiitKit

/// What extensions add to a type, as the checker knows it.
struct ExtensionInfo {
    var computed: [String: TypeAnnotation] = [:]
    var settable: Set<String> = []
    var methods: [String: [Signature]] = [:]
    var staticProperties: [PropertyDecl] = []
    var staticMethods: [String: [Signature]] = [:]
    var conformances: [String] = []

    typealias Signature = TypeChecker.Signature

    mutating func merge(_ other: ExtensionInfo) {
        computed.merge(other.computed) { $1 }
        settable.formUnion(other.settable)
        for (name, signatures) in other.methods { methods[name, default: []] += signatures.map { var s = $0; s.index = methods[name]?.count ?? 0; return s } }
        staticProperties += other.staticProperties
        for (name, signatures) in other.staticMethods { staticMethods[name, default: []] += signatures.map { var s = $0; s.index = staticMethods[name]?.count ?? 0; return s } }
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
    func extensionInfo(for type: TypeAnnotation) -> ExtensionInfo? {
        extensionKey(of: type).flatMap(extensionInfo(forKey:))
    }

    func extensionInfo(forKey key: String) -> ExtensionInfo? {
        var info = localExtensions[key]
        if let members = interpreter.typeExtensions[key] {
            var runtime = ExtensionInfo()
            func signatures(_ sets: [String: OverloadSet]) -> [String: [Signature]] {
                sets.mapValues { set in
                    set.candidates.enumerated().map { index, method in
                        var signature = signature(method)
                        signature.index = index
                        return signature
                    }
                }
            }
            runtime.computed = members.computed.mapValues { $0.returnType ?? .unknown }
            runtime.settable = Set(members.setters.keys)
            runtime.methods = signatures(members.methods)
            runtime.staticProperties = members.staticProperties
            runtime.staticMethods = signatures(members.staticMethods)
            runtime.conformances = members.conformances
            if var existing = info { existing.merge(runtime); info = existing } else { info = runtime }
        }
        return info
    }

    /// Notes what an extension adds, so what is checked before its body can use it.
    func registerExtension(_ decl: ExtensionDecl) {
        var info = ExtensionInfo()
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
            info.computed[property.name] = property.type ?? .unknown
            if property.setter != nil { info.settable.insert(property.name) }
        }
        info.methods = signatures(members.methods)
        info.staticProperties = members.staticProperties
        info.staticMethods = signatures(members.staticMethods)
        info.conformances = decl.conformances
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
            if structInfo(named: key) != nil || enumInfo(named: key) != nil { return .named(key) }
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
        decl.members = members
    }

    /// Whether the type has a member by that name, for a bare name inside it to mean `self`'s.
    func hasMember(_ type: TypeAnnotation, named name: String) -> Bool {
        if let ext = extensionInfo(for: type), ext.computed[name] != nil || ext.methods[name] != nil { return true }
        switch type {
        case .named(let typeName):
            if let info = structInfo(named: typeName) {
                return info.property(name) != nil || info.computed[name] != nil || info.methods[name] != nil
            }
            if let info = enumInfo(named: typeName) { return info.computed[name] != nil || info.methods[name] != nil || name == "rawValue" }
            return false
        default:
            if let (bridgedType, _) = bridged(type) { return bridgedType.members.contains { !$0.isStatic && $0.name == name } }
            return false
        }
    }
}
