import Foundation
import SwiitKit

extension TypeChecker {
    // MARK: Classes

    /// A class's info, with what its superclass gives already in it: a lookup
    /// on the class finds an inherited member as one of its own.
    func classInfo(_ decl: ClassDecl, superclass parent: StructInfo?, conformances: [String]) throws -> StructInfo {
        var members = decl.members
        members.conformances = conformances
        var info = try structInfo(members)
        info.isClass = true
        info.isActor = decl.isActor
        info.superclass = parent?.name
        info.convenienceInitializers = members.initializers.map(\.isConvenience)
        info.overrides = Set(members.methods.filter(\.isOverride).map(\.name))
        // Without a designated initializer of its own, a class has its superclass's.
        if !info.convenienceInitializers.contains(false), let parent {
            let inherited = parent.initializers.map { initializer -> Signature in
                var copy = initializer
                copy.returns = initializer.returns == .optional(.named(parent.name)) ? .optional(.named(decl.name)) : .named(decl.name)
                return copy
            }
            info.initializers += inherited
        }
        // No memberwise initializer: `init()` where every property has a value.
        info.memberwise = Signature(name: decl.name, parameters: [], returns: .named(decl.name))
        guard let parent else { return info }
        info.stored = parent.stored.filter { inherited in !info.stored.contains { $0.name == inherited.name } } + info.stored
        for (name, type) in parent.computed where info.computed[name] == nil { info.computed[name] = type }
        info.settable.formUnion(parent.settable)
        for (name, signatures) in parent.methods {
            let own = info.methods[name] ?? []
            let kept = signatures.filter { inherited in !own.contains { sameParameters($0.parameters, inherited.parameters) } }
            info.methods[name] = own + kept
        }
        for (name, signatures) in parent.staticMethods where info.staticMethods[name] == nil { info.staticMethods[name] = signatures }
        info.staticProperties += parent.staticProperties.filter { inherited in !info.staticProperties.contains { $0.name == inherited.name } }
        if info.subscripts.isEmpty {
            info.subscripts = parent.subscripts
            info.subscriptSettable = parent.subscriptSettable
        }
        info.conformances += parent.conformances.filter { !info.conformances.contains($0) }
        return info
    }

    /// The class and each it comes from, nearest first.
    func classChain(_ info: StructInfo) -> [StructInfo] {
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
            let inherited = parent?.methods[method.name] ?? []
            let overrides = inherited.contains { sameParameters($0.parameters, method.parameters) }
            if method.isOverride && !overrides {
                throw TypeError("\(decl.name).\(method.name) says 'override' but \(parent?.name ?? "the class") has no such method")
            }
            if overrides && !method.isOverride {
                throw TypeError("\(decl.name).\(method.name) overrides a method of \(parent!.name): write 'override'")
            }
        }
        for property in decl.members.properties where property.isOverride {
            guard let parent, parent.property(property.name) != nil || parent.computed[property.name] != nil else {
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
