import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxMacros

@main
struct SwiitKitMacros: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [SwiitExportMacro.self, SwiitObjectMacro.self]
}

struct MacroError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// `@SwiitExport`: a peer `__swiit_export_<name>`, exported to C as
/// `swiit_export_<name>`, that describes the function.
public struct SwiitExportMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax, providingPeersOf declaration: some DeclSyntaxProtocol, in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let function = declaration.as(FunctionDeclSyntax.self) else {
            throw MacroError("@SwiitExport goes on a function; use SwiitEnum for an enum and @SwiitObject for a class")
        }
        let name = function.name.text
        let exported = try exportedFunction(function, receiver: nil)
        // The symbol the shell looks for when it loads the plugin.
        return ["""
        @_cdecl("swiit_export_\(raw: name)")
        public func __swiit_export_\(raw: name)() -> UnsafeMutableRawPointer {
            Unmanaged.passRetained(NativeFunction(\(raw: exported))).toOpaque()
        }
        """]
    }

    // MARK: Functions

    /// `ExportedFunction(…)` for `function`, called on `receiver` if it's a
    /// method (`self`), or as a global function.
    static func exportedFunction(_ function: FunctionDeclSyntax, receiver: String?) throws -> String {
        let name = function.name.text
        let signature = function.signature
        if signature.effectSpecifiers?.asyncSpecifier != nil {
            throw MacroError("\(name): async functions can't be exported yet")
        }
        if function.genericParameterClause != nil {
            throw MacroError("\(name): generic functions can't be exported; give it concrete types")
        }
        let throwing = signature.effectSpecifiers?.throwsClause != nil
        let docs = Documentation(function.leadingTrivia)

        var parameters: [String] = []
        var arguments: [String] = []
        for parameter in signature.parameterClause.parameters {
            let label = parameter.firstName.text == "_" ? nil : parameter.firstName.text
            let parameterName = parameter.secondName?.text ?? parameter.firstName.text
            if parameter.ellipsis != nil {
                throw MacroError("\(name): variadic parameters can't be exported yet; take an array")
            }
            if let attributed = parameter.type.as(AttributedTypeSyntax.self), !attributed.specifiers.isEmpty {
                throw MacroError("\(name): \(parameterName) can't be inout")
            }
            let type = parameter.type.trimmedDescription
            var isInput = false
            var shortFlag: String?
            for attribute in parameter.attributes {
                guard let attribute = attribute.as(AttributeSyntax.self) else { continue }
                switch attribute.attributeName.trimmedDescription {
                case "Input", "SwiitKit.Input":
                    isInput = true
                case "Flag", "SwiitKit.Flag":
                    guard let argument = attribute.arguments?.as(LabeledExprListSyntax.self)?.first?.expression
                        .as(StringLiteralExprSyntax.self)?.representedLiteralValue, argument.count == 1 else {
                        throw MacroError("\(name): @Flag takes one character, like @Flag(\"n\")")
                    }
                    shortFlag = argument
                default:
                    break
                }
            }

            var fields = [
                "label: \(label.map(quoted) ?? "nil")",
                "name: \(quoted(parameterName))",
                "type: swiitParameterType(\(type).self)",
                "enums: swiitParameterEnums(\(type).self)",
            ]
            if isInput { fields.append("isInput: true") }
            if let shortFlag { fields.append("shortFlag: \(quoted(shortFlag))") }
            if let doc = docs.parameters[parameterName] { fields.append("documentation: \(quoted(doc))") }

            var argument = "try swiitArgument(arguments, \(quoted(parameterName)), of: \(quoted(name)), as: \(type).self)"
            if let defaultExpr = parameter.defaultValue?.value {
                if let literal = literalValue(defaultExpr) {
                    fields.append("defaultValue: \(literal)")
                } else {
                    // The shell leaves it out; Swift computes it here.
                    fields.append("defaultSource: \(quoted(defaultExpr.trimmedDescription))")
                    argument = "(arguments[\(quoted(parameterName))] == nil ? (\(defaultExpr.trimmedDescription)) : \(argument))"
                }
            }
            parameters.append("ExportedParameter(\(fields.joined(separator: ", ")))")
            arguments.append((label.map { "\($0): " } ?? "") + argument)
        }

        let callee = receiver.map { "\($0).\(name)" } ?? name
        let call = "\(throwing ? "try " : "")\(callee)(\(arguments.joined(separator: ", ")))"
        let returnType = signature.returnClause.map { "swiitReturnType(\($0.type.trimmedDescription).self)" } ?? "nil"
        let capture = receiver.map { "[\($0)] " } ?? ""
        return """
        ExportedFunction(
            name: \(quoted(name)),
            summary: \(docs.summary.map(quoted) ?? "nil"),
            parameters: [\(parameters.joined(separator: ", "))],
            returnType: \(returnType),
            abiVersion: swiitPluginABIVersion,
            isThrowing: \(throwing),
            call: { \(capture)arguments in try Value(returning: \(call)) }
        )
        """
    }

    /// A default that's a literal, as a `Value` the shell can fill in and
    /// show; nil for anything Swift must compute.
    static func literalValue(_ expr: ExprSyntax) -> String? {
        if let int = expr.as(IntegerLiteralExprSyntax.self) { return ".int(\(int.literal.text))" }
        if let double = expr.as(FloatLiteralExprSyntax.self) { return ".double(\(double.literal.text))" }
        if let bool = expr.as(BooleanLiteralExprSyntax.self) { return ".bool(\(bool.literal.text))" }
        if expr.is(NilLiteralExprSyntax.self) { return ".nothing" }
        if let string = expr.as(StringLiteralExprSyntax.self), let text = string.representedLiteralValue {
            return ".string(\(quoted(text)))"
        }
        if let prefix = expr.as(PrefixOperatorExprSyntax.self), prefix.operator.text == "-",
           let inner = literalValue(prefix.expression), inner.hasPrefix(".int(") || inner.hasPrefix(".double(") {
            let open = inner.firstIndex(of: "(")!
            return inner[...open] + "-" + inner[inner.index(after: open)...]
        }
        if let array = expr.as(ArrayExprSyntax.self) {
            let items = array.elements.map { literalValue($0.expression) }
            guard !items.contains(where: { $0 == nil }) else { return nil }
            return ".list([\(items.map { $0! }.joined(separator: ", "))])"
        }
        return nil
    }

}

/// `@SwiitObject`: the members of a live object, from a class's public
/// properties and methods.
public struct SwiitObjectMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax, attachedTo declaration: some DeclGroupSyntax, providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax], in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let classDecl = declaration.as(ClassDeclSyntax.self) else {
            throw MacroError("@SwiitObject goes on a class; a struct can be returned as Encodable data, and an enum can conform to SwiitEnum")
        }
        // The compiler says which conformances are missing: a class that's
        // already Sendable doesn't get it again.
        let needsSendable = protocols.contains { $0.trimmedDescription.hasSuffix("Sendable") }
        return [try classExtension(classDecl, type: type, needsSendable: needsSendable)]
    }

    static func classExtension(_ decl: ClassDeclSyntax, type: some TypeSyntaxProtocol, needsSendable: Bool) throws -> ExtensionDeclSyntax {
        let name = decl.name.text
        var properties: [String] = []
        var methods: [(String, String)] = []
        var hasDescription = false
        for member in decl.memberBlock.members {
            if let variable = member.decl.as(VariableDeclSyntax.self) {
                let names = variable.bindings.compactMap { $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text }
                if names.contains("description") { hasDescription = true }
                guard isPublic(variable.modifiers), !isStatic(variable.modifiers) else { continue }
                properties += names.filter { $0 != "description" }
            } else if let function = member.decl.as(FunctionDeclSyntax.self),
                      isPublic(function.modifiers), !isStatic(function.modifiers) {
                methods.append((function.name.text, try SwiitExportMacro.exportedFunction(function, receiver: "self")))
            }
        }
        let memberNames = properties + methods.map(\.0)
        let propertyCases = properties.map { "case \(quoted($0)): return (try? Value(returning: self.\($0))) ?? .nothing" }
        let methodCases = methods.map { "case \(quoted($0.0)): return .function(NativeFunction(\($0.1)))" }
        let description = hasDescription ? "" : "public var description: String { \(quoted("<" + name + ">")) }"
        return try ExtensionDeclSyntax("""
        extension \(type.trimmed): SwiitObject\(raw: needsSendable ? ", @unchecked Sendable" : "") {
            public var typeName: String { \(raw: quoted(name)) }
            public var memberNames: [String] { [\(raw: memberNames.map(quoted).joined(separator: ", "))] }
            public func member(_ name: String) -> Value? {
                switch name {
                \(raw: (propertyCases + methodCases).joined(separator: "\n"))
                default: return nil
                }
            }
            \(raw: description)
        }
        """)
    }

    static func isPublic(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { ["public", "open"].contains($0.name.text) }
    }

    static func isStatic(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { ["static", "class"].contains($0.name.text) }
    }
}

// MARK: Helpers

func quoted(_ text: String) -> String {
    var result = "\""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\"": result += "\\\""
        case "\\": result += "\\\\"
        case "\n": result += "\\n"
        case "\t": result += "\\t"
        default: result.unicodeScalars.append(scalar)
        }
    }
    return result + "\""
}

/// A `///` doc comment: its summary, and `- Parameter name:` lines (or a
/// `- Parameters:` list), as Swiit reads its own functions' comments.
struct Documentation {
    var summary: String?
    var parameters: [String: String] = [:]

    init(_ trivia: Trivia) {
        let lines = trivia.compactMap { piece -> String? in
            if case .docLineComment(let text) = piece {
                return String(text.dropFirst(3)).trimmingCharacters(in: " ")
            }
            return nil
        }
        var summaryLines: [String] = []
        var inParameters = false
        for line in lines {
            if line.hasPrefix("- Parameters:") {
                inParameters = true
            } else if line.hasPrefix("- Parameter ") {
                add(String(line.dropFirst("- Parameter ".count)))
            } else if inParameters && line.hasPrefix("- ") {
                add(String(line.dropFirst(2)))
            } else if !line.hasPrefix("- ") && parameters.isEmpty && !inParameters {
                summaryLines.append(line)
            }
        }
        let summary = summaryLines.joined(separator: " ").trimmingCharacters(in: " ")
        self.summary = summary.isEmpty ? nil : summary
    }

    private mutating func add(_ entry: String) {
        guard let colon = entry.firstIndex(of: ":") else { return }
        parameters[String(entry[..<colon])] = String(entry[entry.index(after: colon)...]).trimmingCharacters(in: " ")
    }
}

extension String {
    func trimmingCharacters(in set: Character) -> String {
        var result = Substring(self)
        while result.first == set { result.removeFirst() }
        while result.last == set { result.removeLast() }
        return String(result)
    }
}
