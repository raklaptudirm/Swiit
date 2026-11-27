import Foundation

// Declarations as Swift source: functions, properties, and the types a program declares.

extension SwiftPrinter {
    func parameters(_ parameters: [Parameter], closure: Bool = false) -> String {
        parameters.map { parameter in
            var text: String
            // A closure's parameters have no labels to write.
            if closure {
                text = parameter.name
            } else if parameter.label == nil {
                text = "_ \(parameter.name)"
            } else if parameter.label == parameter.name {
                text = parameter.name
            } else {
                text = "\(parameter.label!) \(parameter.name)"
            }
            if closure ? (parameter.type != .any || parameter.variadic) : true {
                text += ": \(parameter.type)" + (parameter.variadic ? "..." : "")
            }
            if let value = parameter.defaultValue { text += " = \(expression(value))" }
            return text
        }
        .joined(separator: ", ")
    }

    /// A declaration's `///` comment as lines: the summary, then each parameter's note.
    func documentation(_ documentation: Documentation?) -> [String] {
        guard let documentation else { return [] }
        return documentation.summary.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            + documentation.parameters.sorted { $0.key < $1.key }
            .map { "- Parameter \($0.key): \($0.value)" }
    }

    func function(_ decl: FunctionDecl, keyword: String, indent: Int) -> String {
        // An initializer is written `init(…)`, and is never marked `mutating`.
        let isInitializer = keyword == "init"
        var text =
            (decl.isMutating && !isInitializer ? "mutating " : "")
            + (isInitializer ? "init" : "\(keyword) \(decl.name)")
        if !decl.generics.isEmpty {
            text +=
                "<"
                + decl.generics
                .map { parameter in
                    let protocols = parameter.constraints.compactMap { constraint -> String? in
                        if case .conforms(let proto) = constraint { proto.description } else { nil }
                    }
                    return protocols.isEmpty
                        ? parameter.name
                        : "\(parameter.name): \(protocols.joined(separator: " & "))"
                }
                .joined(separator: ", ") + ">"
        }
        text += "(\(parameters(decl.parameters)))"
        if decl.isAsync { text += " async" }
        if decl.isRethrowing { text += " rethrows" } else if decl.isThrowing { text += " throws" }
        if let returnType = decl.returnType { text += " -> \(returnType)" }
        return text + " " + block(decl.body, indent: indent)
    }

    func property(_ decl: PropertyDecl, prefix: String, indent: Int) -> String {
        let p = pad(indent)
        if let getter = decl.getter {
            return
                "\(p)\(prefix)var \(decl.name): \(decl.type.map(\.description) ?? "Any") \(block(getter, indent: indent))"
        }
        var text = "\(p)\(prefix)\(decl.mutable ? "var" : "let") \(decl.name)"
        if let type = decl.type { text += ": \(type)" }
        if let value = decl.defaultValue { text += " = \(expression(value))" }
        return text
    }

    func structure(_ decl: StructDecl, indent: Int) -> String {
        let p = pad(indent)
        var text = "\(p)struct \(decl.name)"
        if !decl.conformances.isEmpty { text += ": " + decl.conformances.joined(separator: ", ") }
        var members: [String] = []
        members += decl.staticProperties.map { property($0, prefix: "static ", indent: indent + 1) }
        members += decl.properties.map { property($0, prefix: "", indent: indent + 1) }
        members += decl.initializers.map {
            pad(indent + 1) + function($0, keyword: "init", indent: indent + 1)
        }
        members += decl.staticMethods.map {
            pad(indent + 1) + "static " + function($0, keyword: "func", indent: indent + 1)
        }
        members += decl.methods.map {
            pad(indent + 1) + function($0, keyword: "func", indent: indent + 1)
        }
        return text + " {\n" + members.joined(separator: "\n") + (members.isEmpty ? "" : "\n")
            + "\(p)}"
    }

    /// A class or an actor: its members as a struct's are printed, under its own heading.
    func classText(_ decl: ClassDecl, indent: Int) -> [String] {
        let p = pad(indent)
        let text = structure(decl.members, indent: indent)
        let heading = "\(p)struct \(decl.members.name)"
        return [
            p + (decl.isActor ? "actor " : "class ") + decl.name
                + (decl.inherited.isEmpty ? "" : ": " + decl.inherited.joined(separator: ", "))
                + String(text.dropFirst(heading.count))
        ]
    }

    /// A protocol, by its name and what it inherits.
    func protocolText(_ decl: ProtocolDecl, indent: Int) -> [String] {
        let p = pad(indent)
        return [
            p + "protocol \(decl.name)"
                + (decl.inherited.isEmpty ? "" : ": " + decl.inherited.joined(separator: ", "))
                + " {}"
        ]
    }

    /// An extension of methods the checker gathered.
    func methodsText(_ name: String, _ methods: [FunctionDecl], indent: Int) -> [String] {
        let p = pad(indent)
        let inner = methods.map {
            pad(indent + 1) + function($0, keyword: "func", indent: indent + 1)
        }
        return ["\(p)extension \(name) {\n" + inner.joined(separator: "\n") + "\n\(p)}"]
    }

    func typeExtension(_ decl: ExtensionDecl, indent: Int) -> String {
        let text = structure(decl.members, indent: indent)
        let heading = "\(pad(indent))struct \(decl.members.name)"
        return "\(pad(indent))extension \(decl.typeName)"
            + (decl.conformances.isEmpty ? "" : ": " + decl.conformances.joined(separator: ", "))
            + text.dropFirst(heading.count)
    }

    func enumeration(_ decl: EnumDecl, indent: Int) -> String {
        let p = pad(indent)
        var inherited: [String] = []
        if let raw = decl.rawType { inherited.append(raw.description) }
        inherited += decl.conformances
        var text =
            "\(p)enum \(decl.name)"
            + (inherited.isEmpty ? "" : ": " + inherited.joined(separator: ", ")) + " {\n"
        for enumCase in decl.cases {
            var line = "\(pad(indent + 1))case \(enumCase.name)"
            if !enumCase.associated.isEmpty {
                line +=
                    "("
                    + enumCase.associated
                    .map { value in
                        (value.label.map { "\($0): " } ?? "") + value.type.description
                    }
                    .joined(separator: ", ") + ")"
            }
            if let raw = enumCase.rawValue { line += " = \(expression(raw))" }
            text += line + "\n"
        }
        return text + "\(p)}"
    }
}
