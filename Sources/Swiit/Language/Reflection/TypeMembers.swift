import Foundation
import SwishKit

/// What a type has, for `help Type` and `members`: a Swift type's members
/// from the bridge (with Swish's own extensions, and for a sequence the
/// shell's additions), a struct's or enum's from its declaration. One
/// description, so what's shown is what can be called.
@_spi(Shell) public struct TypeDescription {
    /// What a member is; the order of the cases is the order `help` shows
    /// them in.
    @_spi(Shell) public enum Kind: String, CaseIterable {
        case `case`, initializer, property, method
        case staticProperty = "static property", staticMethod = "static method"

        /// The heading `help` lists them under: "Properties", "Static methods".
        @_spi(Shell) public var heading: String {
            let plural = rawValue.hasSuffix("y") ? rawValue.dropLast() + "ies" : rawValue + "s"
            return plural.prefix(1).uppercased() + plural.dropFirst()
        }
    }

    @_spi(Shell) public struct Member {
        @_spi(Shell) public let name: String
        @_spi(Shell) public let kind: Kind
        /// As Swift writes it: `count: Int`, `uppercased() -> String`.
        @_spi(Shell) public let signature: AttributedString
        @_spi(Shell) public let summary: String
    
        @_spi(Shell) public init(name: String, kind: Kind, signature: AttributedString, summary: String) {
            self.name = name
            self.kind = kind
            self.signature = signature
            self.summary = summary
        }
    }

    @_spi(Shell) public let name: String
    /// What kind of type: "Swift type", "struct" or "enum".
    @_spi(Shell) public let kind: String
    @_spi(Shell) public let members: [Member]

    @_spi(Shell) public init(name: String, kind: String, members: [Member]) {
        self.name = name
        self.kind = kind
        self.members = members
    }
}

extension Interpreter {
    /// The type named `name`, if Swish knows one by that name.
    @_spi(Shell) public func typeDescription(named name: String) -> TypeDescription? {
        if let bridged = Bridge.types[name] { return describe(bridged) }
        switch lookup(name)?.value {
        case .object(let type as StructType)?: return describe(type)
        case .object(let type as EnumType)?: return describe(type)
        default: return nil
        }
    }

    /// The name `typeDescription` knows a value's type by.
    @_spi(Shell) public func describedTypeName(of value: Value) -> String? {
        if case .record(let record) = value { return record.typeName }
        return TypeChecker(interpreter: self).type(of: value).swiftType?.name
    }

    private func describe(_ type: BridgedType) -> TypeDescription {
        var members = type.members.filter { $0.kind != .setter }.map { member in
            let settable = member.kind == .property
                && type.members.contains { $0.kind == .setter && $0.name == member.name }
            let kind: TypeDescription.Kind = switch member.kind {
            case .initializer: .initializer
            case .property, .setter: member.isStatic ? .staticProperty : .property
            case .method: member.isStatic ? .staticMethod : .method
            }
            return TypeDescription.Member(
                name: member.kind == .initializer ? "init" : member.name,
                kind: kind,
                signature: TypeDescription.signature(member, settable: settable),
                summary: member.summary
            )
        }
        // A sequence has the shell's additions too: `select`, `get`, …
        if type.conformances["Sequence"] != nil {
            for (name, methods) in sequenceMethods.sorted(by: { $0.key < $1.key }) {
                for method in methods.candidates {
                    members.append(.init(name: name, kind: .method, signature: TypeDescription.signature(method),
                                         summary: method.documentation?.summary.firstLine ?? ""))
                }
            }
        }
        return TypeDescription(name: type.name, kind: "Swift type", members: members)
    }

    private func describe(_ type: StructType) -> TypeDescription {
        var members: [TypeDescription.Member] = []
        let initializers = type.initializers?.candidates ?? [type.memberwise]
        for initializer in initializers {
            members.append(.init(name: "init", kind: .initializer, signature: TypeDescription.signature(initializer, as: "init"),
                                 summary: initializer.documentation?.summary.firstLine ?? ""))
        }
        for property in type.stored {
            members.append(.init(name: property.name, kind: .property,
                                 signature: AttributedString(joining: TypeDescription.property(property.name, property.type ?? .any, mutable: property.mutable)),
                                 summary: ""))
        }
        for (name, getter) in type.computed.sorted(by: { $0.key < $1.key }) {
            members.append(.init(name: name, kind: .property,
                                 signature: AttributedString(joining: TypeDescription.property(name, getter.returnType ?? .any, mutable: nil)),
                                 summary: getter.documentation?.summary.firstLine ?? ""))
        }
        for (name, methods) in type.methods.sorted(by: { $0.key < $1.key }) {
            for method in methods.candidates {
                members.append(.init(name: name, kind: .method,
                                     signature: TypeDescription.signature(method),
                                     summary: method.documentation?.summary.firstLine ?? ""))
            }
        }
        return TypeDescription(name: type.name, kind: "struct", members: members)
    }

    private func describe(_ type: EnumType) -> TypeDescription {
        let payloads = enumPayloadTypes[ObjectIdentifier(type)] ?? [:]
        let members = type.cases.map { enumCase -> TypeDescription.Member in
            var signature: [AttributedString] = [.init("case", .keyword), .init(" "), .init(enumCase.name, .command)]
            if !enumCase.labels.isEmpty {
                let types = payloads[enumCase.name] ?? []
                signature.append(.init("("))
                for (index, label) in enumCase.labels.enumerated() {
                    if index > 0 { signature.append(.init(", ")) }
                    if let label { signature += [.init(label, .variable), .init(": ")] }
                    signature += (index < types.count ? types[index] : .any).styled
                }
                signature.append(.init(")"))
            }
            if let raw = enumCase.rawValue {
                let isText = if case .string = raw { true } else { false }
                signature += [.init(" = "), .init(raw.debugDescription, isText ? .string : .constant)]
            }
            return .init(name: enumCase.name, kind: .case, signature: AttributedString(joining: signature), summary: "")
        }
        return TypeDescription(name: type.name, kind: "enum", members: members)
    }

    /// What `help Type` shows: its members, grouped by kind, each with its
    /// signature (highlighted as Swift) and, on the line below, what its
    /// documentation says.
    @_spi(Shell) public func helpLines(for type: TypeDescription) -> [AttributedString] {
        var lines = [AttributedString(joining: [.init(type.kind, DisplayStyle.keyword), .init(" "), .init(type.name, DisplayStyle.type)])]
        let groups = Dictionary(grouping: type.members, by: \.kind)
        for kind in TypeDescription.Kind.allCases {
            guard let members = groups[kind], !members.isEmpty else { continue }
            lines += [AttributedString(""), HelpStyle.heading("\(kind.heading):")]
            for (index, member) in members.sorted(by: { $0.name < $1.name }).enumerated() {
                // A blank line between them, so a signature and its description read as one.
                if index > 0 { lines.append(AttributedString("")) }
                lines.append(AttributedString(joining: [AttributedString("  "), member.signature]))
                if !member.summary.isEmpty { lines.append(AttributedString("    ") + AttributedString(documentation: member.summary)) }
            }
        }
        return lines
    }
}

extension TypeDescription {
    /// A bridged member as Swift declares it, in pieces by what each is.
    @_spi(Shell) public static func signature(_ member: BridgedMember, settable: Bool) -> AttributedString {
        var pieces: [AttributedString] = []
        switch member.kind {
        case .initializer:
            pieces += [.init("init", .keyword), .init("(")] + parameters(member.parameters) + [.init(")")]
        case .property:
            pieces += [.init(member.name, .command), .init(": ")] + member.returns.styled
            if settable { pieces += [.init(" { "), .init("get", .keyword), .init(" "), .init("set", .keyword), .init(" }")] }
        case .method, .setter:
            pieces += [.init(member.name, .command), .init("(")] + parameters(member.parameters) + [.init(")")]
            if member.returns != .void { pieces += [.init(" -> ")] + member.returns.styled }
        }
        return AttributedString(joining: pieces)
    }

    /// A Swish function as a member, under `name` if given: its input is
    /// what it's called on, so it isn't shown.
    @_spi(Shell) public static func signature(_ function: Function, as name: String? = nil) -> AttributedString {
        AttributedString(joining: (function.isMutating ? [AttributedString("mutating", .keyword), .init(" ")] : [])
                   + function.declaration(as: name, nameStyle: name == "init" ? .keyword : .command) { $0.isInput })
    }

    /// `let x: Int`, `var x: Int`, or with no `mutable`, a computed
    /// `var x: Int { get }`.
    @_spi(Shell) public static func property(_ name: String, _ type: TypeAnnotation, mutable: Bool?) -> [AttributedString] {
        [.init(mutable == false ? "let" : "var", .keyword), .init(" "), .init(name, .command), .init(": ")] + type.styled
            + (mutable == nil ? [.init(" { "), .init("get", .keyword), .init(" }")] : [])
    }

    private static func parameters(_ parameters: [Parameter]) -> [AttributedString] {
        parameters.enumerated().flatMap { index, parameter in (index > 0 ? [AttributedString(", ")] : []) + parameter.declaration }
    }
}

private extension String {
    /// The first line: a documentation summary's first sentence's line.
    @_spi(Shell) public var firstLine: String { String(prefix { $0 != "\n" }) }
}
