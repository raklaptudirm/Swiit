import Foundation
import SwiitKit

// What the checker knows of a type, in one place. A type's members are declared in one of several places (a struct,
// class or actor; an enum; a protocol; the extensions on any of them, and on Swift's own types) and each kept its own
// description, so every question about a member (its type, how to call it, whether it can be set) was asked of each in
// turn. A `TypeProfile` gathers them: ask it once.

/// A property of a type: stored or computed.
struct MemberProperty {
    var type: TypeAnnotation
    /// A `var` or a computed property with a setter; a protocol's `{ get set }`.
    var isSettable: Bool
    /// The declaration, if it is a stored property.
    var stored: PropertyDecl?
}

/// MemberSet of one kind of place: what the type declares, or what extensions add.
struct MemberSet {
    var properties: [String: MemberProperty] = [:]
    var methods: [String: [TypeChecker.Signature]] = [:]
    var staticProperties: [String: TypeAnnotation] = [:]
    var staticMethods: [String: [TypeChecker.Signature]] = [:]
    var initializers: [TypeChecker.Signature] = []
}

/// Which set of overloads a method is among, as the interpreter keeps them: the type's own, or the extensions'. A call
/// the checker resolved says which of that set it chose, so the two can't be mixed in one list.
enum MemberOrigin { case declaration, extensions }

/// What `name` is on a type.
enum FoundMember {
    case property(MemberProperty)
    case methods([TypeChecker.Signature], from: MemberOrigin)
    /// A case of an enum, on the type.
    case enumCase
}

struct TypeProfile {
    enum Kind { case structure, classType, actor, enumeration, protocolType, other }

    var name: String
    var kind: Kind
    var superclass: String?
    var conformances: [String] = []
    /// An enum's cases, and the type of its raw values.
    var cases: [(name: String, payload: [AssociatedValue])] = []
    var rawType: TypeAnnotation?
    var typeParameters: [String] = []
    /// What the type declares itself (for a class, with what its superclass gives), and what extensions add: those of
    /// the type, of the protocols it conforms to, and of its superclasses.
    var declared = MemberSet()
    var extended = MemberSet()
    /// A struct with no initializer of its own is made by its memberwise one.
    var memberwise: TypeChecker.Signature?

    var isClass: Bool { kind == .classType || kind == .actor }

    /// The initializers a call chooses among: the type's own (or its memberwise one), and those extensions add.
    var initializers: [TypeChecker.Signature] { (declared.initializers.isEmpty ? memberwise.map { [$0] } ?? [] : declared.initializers) + extended.initializers }

    /// Whether a call of an initializer names which it chose, to the interpreter: it keeps the type's own as a set of overloads
    /// that a value type's are in, with none added by extensions, which it keeps apart.
    var namesItsInitializers: Bool { !declared.initializers.isEmpty && !isClass && extended.initializers.isEmpty }

    /// What `name` is on a value of the type: its own members first, then what extensions add.
    func instanceMember(_ name: String) -> FoundMember? {
        if let property = declared.properties[name] { return .property(property) }
        if let methods = declared.methods[name] { return .methods(methods, from: .declaration) }
        if let property = extended.properties[name] { return .property(property) }
        if let methods = extended.methods[name] { return .methods(methods, from: .extensions) }
        return nil
    }

    /// Every static method by that name, the type's own and those extensions add: for an operator, which the overloads of
    /// both are candidates of.
    func staticMethods(named name: String) -> [TypeChecker.Signature] { (declared.staticMethods[name] ?? []) + (extended.staticMethods[name] ?? []) }

    /// What `name` is on the type itself: a static property or method, or a case of an enum.
    func staticMember(_ name: String) -> FoundMember? {
        if let type = declared.staticProperties[name] ?? extended.staticProperties[name] {
            return .property(MemberProperty(type: type, isSettable: true, stored: nil))
        }
        if let methods = declared.staticMethods[name] { return .methods(methods, from: .declaration) }
        if let methods = extended.staticMethods[name] { return .methods(methods, from: .extensions) }
        if cases.contains(where: { $0.name == name }) { return .enumCase }
        return nil
    }
}


extension TypeChecker {
    /// What is known of `type`, if it names a type with members of its own or ones an extension adds.
    func describe(_ type: TypeAnnotation) -> TypeProfile? {
        guard let key = extensionKey(of: type) else { return nil }
        return describe(named: key)
    }

    func describe(named key: String) -> TypeProfile? {
        var description: TypeProfile
        switch lookup(key) {
        case .structType(let info)?:
            description = TypeProfile(name: info.name, kind: info.isActor ? .actor : info.isClass ? .classType : .structure)
            description.superclass = info.superclass
            description.conformances = info.conformances
            description.declared = members(of: info)
            description.memberwise = info.memberwise
        case .enumType(let info)?:
            description = TypeProfile(name: info.name, kind: .enumeration)
            description.conformances = info.conformances
            description.cases = info.cases
            description.rawType = info.rawType
            description.typeParameters = info.typeParameters
            description.declared = members(of: info)
            // What Swift synthesizes for an enum: `rawValue` where it has raw values, `allCases` where no case has associated values.
            // (A Swiit enum isn't a Swift type the bridge could describe, so they are made here.)
            if let raw = info.rawType { description.declared.properties["rawValue"] = MemberProperty(type: raw, isSettable: false, stored: nil) }
            if info.cases.allSatisfy({ $0.payload.isEmpty }) { description.declared.staticProperties["allCases"] = .list(.named(info.name)) }
        case .protocolType?:
            description = TypeProfile(name: key, kind: .protocolType)
            description.declared = requirementMembers(of: key)
        default:
            guard let ext = extensionInfo(forKey: key) else { return nil }
            description = TypeProfile(name: key, kind: .other)
            description.extended = members(of: ext)
            description.conformances = ext.conformances
            return description
        }
        if let ext = extensionInfo(forKey: key) {
            description.extended = members(of: ext)
            description.conformances += ext.conformances
        }
        return description
    }

    private func members(of info: StructInfo) -> MemberSet {
        var members = MemberSet()
        for property in info.stored { members.properties[property.name] = MemberProperty(type: property.type ?? .unknown, isSettable: property.mutable, stored: property) }
        for (name, type) in info.computed where members.properties[name] == nil {
            members.properties[name] = MemberProperty(type: type, isSettable: info.settable.contains(name), stored: nil)
        }
        members.methods = info.methods
        for property in info.staticProperties { members.staticProperties[property.name] = property.type ?? .unknown }
        members.staticMethods = info.staticMethods
        members.initializers = info.initializers
        return members
    }

    private func members(of info: EnumInfo) -> MemberSet {
        var members = MemberSet()
        for (name, type) in info.computed { members.properties[name] = MemberProperty(type: type, isSettable: false, stored: nil) }
        members.methods = info.methods
        for property in info.staticProperties { members.staticProperties[property.name] = property.type ?? .unknown }
        members.staticMethods = info.staticMethods
        members.initializers = info.initializers
        return members
    }

    private func members(of info: ExtensionInfo) -> MemberSet {
        var members = MemberSet()
        for (name, type) in info.computed { members.properties[name] = MemberProperty(type: type, isSettable: info.settable.contains(name), stored: nil) }
        members.methods = info.methods
        for property in info.staticProperties { members.staticProperties[property.name] = property.type ?? .unknown }
        members.staticMethods = info.staticMethods
        members.initializers = info.initializers
        return members
    }

    /// What a protocol asks, with what each protocol it takes in asks.
    private func requirementMembers(of name: String) -> MemberSet {
        var members = MemberSet()
        for required in protocolClosure(name).compactMap({ protocolInfo(named: $0) }) {
            for (property, requirement) in required.properties where members.properties[property] == nil {
                members.properties[property] = MemberProperty(type: requirement.type, isSettable: requirement.settable, stored: nil)
            }
            for (method, signatures) in required.methods { members.methods[method, default: []] += signatures }
            for (property, type) in required.staticProperties where members.staticProperties[property] == nil { members.staticProperties[property] = type }
            for (method, signatures) in required.staticMethods { members.staticMethods[method, default: []] += signatures }
            members.initializers += required.initializers
        }
        for (method, signatures) in members.methods {
            members.methods[method] = signatures.enumerated().map { index, signature in var copy = signature; copy.index = index; return copy }
        }
        return members
    }
}
