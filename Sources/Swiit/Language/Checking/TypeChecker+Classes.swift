import Foundation

extension TypeChecker {
    // MARK: Classes

    /// A class's info, with what its superclass gives already in it: a lookup
    /// on the class finds an inherited member as one of its own.
    func classInfo(_ decl: ClassDecl, superclass parent: TypeProfile?, conformances: [String]) throws -> TypeProfile {
        var members = decl.members
        members.conformances = conformances
        var info = try structInfo(members)
        info.kind = decl.isActor ? .actor : .classType
        info.superclass = parent?.name
        info.convenienceInitializers = members.initializers.map(\.isConvenience)
        info.nonisolated = Set(members.methods.filter(\.isNonisolated).map(\.name) + members.properties.filter(\.isNonisolated).map(\.name))
        info.overrides = Set(members.methods.filter(\.isOverride).map(\.name))
        // Without a designated initializer of its own, a class has its superclass's.
        if !info.convenienceInitializers.contains(false), let parent {
            let inherited = parent.declared.initializers.map { initializer -> Signature in
                var copy = initializer
                copy.returns = initializer.returns == .optional(.named(parent.name)) ? .optional(.named(decl.name)) : .named(decl.name)
                return copy
            }
            info.declared.initializers += inherited
        }
        // No memberwise initializer: `init()` where every property has a value.
        info.memberwise = Signature(name: decl.name, parameters: [], returns: .named(decl.name))
        guard let parent else { return info }
        for (name, property) in parent.declared.properties where info.declared.properties[name] == nil { info.declared.properties[name] = property }
        for (name, signatures) in parent.declared.methods {
            let own = info.declared.methods[name] ?? []
            let kept = signatures.filter { inherited in !own.contains { sameParameters($0.parameters, inherited.parameters) } }
            info.declared.methods[name] = own + kept
        }
        for (name, signatures) in parent.declared.staticMethods where info.declared.staticMethods[name] == nil { info.declared.staticMethods[name] = signatures }
        for (name, property) in parent.declared.staticProperties where info.declared.staticProperties[name] == nil { info.declared.staticProperties[name] = property }
        if info.subscripts.isEmpty {
            info.subscripts = parent.subscripts
            info.subscriptSettable = parent.subscriptSettable
        }
        info.conformances += parent.conformances.filter { !info.conformances.contains($0) }
        return info
    }

    /// The class and each it comes from, nearest first.
    func classChain(_ info: TypeProfile) -> [TypeProfile] {
        var result = [info]
        var current = info
        while let name = current.superclass, let next = structInfo(named: name), !result.contains(where: { $0.name == next.name }) {
            result.append(next)
            current = next
        }
        return result
    }

    /// Whether `name` is `other` or comes from it.
    func isSubclass(_ name: String, of other: String) -> Bool {
        guard let info = structInfo(named: name), info.isClass else { return false }
        return classChain(info).contains { $0.name == other }
    }

    /// Checks a class's body, its overrides, and its `deinit`.
    func checkClass(_ decl: inout ClassDecl) throws {
        guard let info = structInfo(named: decl.name) else { return }
        let parent = info.superclass.flatMap(structInfo(named:))
        for method in decl.members.methods {
            let inherited = parent?.declared.methods[method.name] ?? []
            let overrides = inherited.contains { sameParameters($0.parameters, method.parameters) }
            if method.isOverride && !overrides {
                throw TypeError("\(decl.name).\(method.name) says 'override' but \(parent?.name ?? "the class") has no such method")
            }
            if overrides && !method.isOverride {
                throw TypeError("\(decl.name).\(method.name) overrides a method of \(parent!.name): write 'override'")
            }
        }
        for property in decl.members.properties where property.isOverride {
            guard let parent, parent.declared.properties[property.name] != nil else {
                throw TypeError("\(decl.name).\(property.name) says 'override' but \(parent?.name ?? "the class") has no such property")
            }
        }
        try checkStruct(&decl.members, isClass: true)
        if let body = decl.deinitializer {
            var function = FunctionDecl(name: "deinit", parameters: [], body: body)
            try checkFunction(&function, self: .named(decl.name), mutating: true)
            decl.deinitializer = function.body
        }
    }
}
