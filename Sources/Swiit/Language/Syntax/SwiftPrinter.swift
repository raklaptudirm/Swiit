import Foundation
import SwishKit

/// Prints the core's tree as Swift source: the form every construct reduces
/// to (Docs/Design/desugaring.md). It is for golden tests of what a rewrite
/// produces, `--emit-swift`, and later compiling the result with `swiftc` to
/// compare with the interpreter. A construct a layer over the core adds, or
/// that only the checker makes, prints as a comment saying so, so printing is
/// total and the gap is visible.
@_spi(Shell) public struct SwiftPrinter {
    @_spi(Shell) public init() {}

    /// The program as source, one statement a line.
    @_spi(Shell) public func source(_ program: Program) -> String {
        lines(program, indent: 0).joined(separator: "\n")
    }

    /// One expression as source.
    @_spi(Shell) public func source(_ expr: Expr) -> String {
        expression(expr)
    }

    // MARK: Statements

    private func lines(_ program: Program, indent: Int) -> [String] {
        program.statements.flatMap { statement($0, indent: indent) }
    }

    private func pad(_ indent: Int) -> String { String(repeating: "    ", count: indent) }

    private func block(_ program: Program, indent: Int) -> String {
        let inner = lines(program, indent: indent + 1)
        if inner.isEmpty { return "{}" }
        return "{\n" + inner.joined(separator: "\n") + "\n" + pad(indent) + "}"
    }

    private func statement(_ statement: Statement, indent: Int) -> [String] {
        let p = pad(indent)
        switch statement {
        case .declare(let name, let mutable, let value):
            let keyword = mutable ? "var" : "let"
            if case .annotated(let inner, let type) = value {
                return ["\(p)\(keyword) \(name): \(type) = \(expression(inner))"]
            }
            return ["\(p)\(keyword) \(name) = \(expression(value))"]
        case .assign(let assignment):
            var target = assignment.root
            for step in assignment.path {
                switch step {
                case .member(let name): target += ".\(name)"
                case .index(let index): target += "[\(expression(index))]"
                }
            }
            let op = assignment.op.map { "\($0.rawValue)=" } ?? "="
            return ["\(p)\(target) \(op) \(expression(assignment.value))"]
        case .function(let decl):
            return [p + function(decl, keyword: "func", indent: indent)]
        case .doCatch(let body, let errorName, let handler):
            var text = "\(p)do \(block(body, indent: indent))"
            if let handler {
                text += errorName == "error" ? " catch " : " catch let \(errorName) "
                text += block(handler, indent: indent)
            }
            return [text]
        case .enumDecl(let decl):
            return [enumeration(decl, indent: indent)]
        case .structDecl(let decl):
            return [structure(decl, indent: indent)]
        case .extensionDecl(let name, let methods):
            let inner = methods.map { pad(indent + 1) + function($0, keyword: "func", indent: indent + 1) }
            return ["\(p)extension \(name) {\n" + inner.joined(separator: "\n") + "\n\(p)}"]
        case .extended:
            return ["\(p)/* a construct from a layer over the core */"]
        case .deferBlock(let body):
            return ["\(p)defer \(block(body, indent: indent))"]
        case .fallthroughStatement:
            return ["\(p)fallthrough"]
        case .returnStatement(let value):
            return [value.map { "\(p)return \(expression($0))" } ?? "\(p)return"]
        case .guardStatement(let condition, let otherwise):
            return ["\(p)guard \(conditionText(condition)) else \(block(otherwise, indent: indent))"]
        case .breakStatement:
            return ["\(p)break"]
        case .continueStatement:
            return ["\(p)continue"]
        case .expression(let expr):
            return [p + expression(expr)]
        case .ifStatement(let node):
            return [p + ifText(node, indent: indent)]
        case .switchStatement(let node):
            var text = "switch \(expression(node.subject)) {\n"
            for switchCase in node.cases {
                if switchCase.patterns.isEmpty {
                    text += "\(p)default:\n"
                } else {
                    text += "\(p)case \(switchCase.patterns.map(pattern).joined(separator: ", "))"
                    text += switchCase.guardExpr.map { " where \(expression($0))" } ?? ""
                    text += ":\n"
                }
                let inner = lines(switchCase.body, indent: indent + 1)
                text += (inner.isEmpty ? [pad(indent + 1) + "break"] : inner).joined(separator: "\n") + "\n"
            }
            return [p + text + "\(p)}"]
        case .forLoop(let loop):
            return [p + "for \(loop.variable) in \(expression(loop.sequence)) \(block(loop.body, indent: indent))"]
        case .whileLoop(let loop):
            return [p + "while \(expression(loop.condition)) \(block(loop.body, indent: indent))"]
        }
    }

    private func ifText(_ node: IfStatement, indent: Int) -> String {
        var text = "if \(conditionText(node.condition)) \(block(node.then, indent: indent))"
        if let otherwise = node.otherwise {
            // `else if`: an else holding only an `if`.
            if otherwise.statements.count == 1, case .ifStatement(let nested) = otherwise.statements[0] {
                text += " else " + ifText(nested, indent: indent)
            } else {
                text += " else \(block(otherwise, indent: indent))"
            }
        }
        return text
    }

    private func conditionText(_ condition: IfStatement.Condition) -> String {
        switch condition {
        case .expression(let expr): expression(expr)
        case .binding(let name, let mutable, let value): "\(mutable ? "var" : "let") \(name) = \(expression(value))"
        case .pattern(let p, let value): "case \(pattern(p)) = \(expression(value))"
        }
    }

    // MARK: Declarations

    private func parameters(_ parameters: [Parameter], closure: Bool = false) -> String {
        parameters.map { parameter in
            var text: String
            // A closure's parameters have no labels to write.
            if closure { text = parameter.name }
            else if parameter.label == nil { text = "_ \(parameter.name)" }
            else if parameter.label == parameter.name { text = parameter.name }
            else { text = "\(parameter.label!) \(parameter.name)" }
            if parameter.type != .any || parameter.variadic { text += ": \(parameter.type)" + (parameter.variadic ? "..." : "") }
            if let value = parameter.defaultValue { text += " = \(expression(value))" }
            return text
        }.joined(separator: ", ")
    }

    private func function(_ decl: FunctionDecl, keyword: String, indent: Int) -> String {
        // An initializer is written `init(…)`, and is never marked `mutating`.
        let isInitializer = keyword == "init"
        var text = (decl.isMutating && !isInitializer ? "mutating " : "") + (isInitializer ? "init" : "\(keyword) \(decl.name)")
        if !decl.generics.isEmpty {
            text += "<" + decl.generics.sorted { $0.key < $1.key }.map { name, protocols in
                protocols.isEmpty ? name : "\(name): \(protocols.joined(separator: " & "))"
            }.joined(separator: ", ") + ">"
        }
        text += "(\(parameters(decl.parameters)))"
        if decl.isRethrowing { text += " rethrows" } else if decl.isThrowing { text += " throws" }
        if let returnType = decl.returnType { text += " -> \(returnType)" }
        return text + " " + block(decl.body, indent: indent)
    }

    private func property(_ decl: PropertyDecl, prefix: String, indent: Int) -> String {
        let p = pad(indent)
        if let getter = decl.getter {
            return "\(p)\(prefix)var \(decl.name): \(decl.type.map(\.description) ?? "Any") \(block(getter, indent: indent))"
        }
        var text = "\(p)\(prefix)\(decl.mutable ? "var" : "let") \(decl.name)"
        if let type = decl.type { text += ": \(type)" }
        if let value = decl.defaultValue { text += " = \(expression(value))" }
        return text
    }

    private func structure(_ decl: StructDecl, indent: Int) -> String {
        let p = pad(indent)
        var text = "\(p)struct \(decl.name)"
        if !decl.conformances.isEmpty { text += ": " + decl.conformances.joined(separator: ", ") }
        var members: [String] = []
        members += decl.staticProperties.map { property($0, prefix: "static ", indent: indent + 1) }
        members += decl.properties.map { property($0, prefix: "", indent: indent + 1) }
        members += decl.initializers.map { pad(indent + 1) + function($0, keyword: "init", indent: indent + 1) }
        members += decl.staticMethods.map { pad(indent + 1) + "static " + function($0, keyword: "func", indent: indent + 1) }
        members += decl.methods.map { pad(indent + 1) + function($0, keyword: "func", indent: indent + 1) }
        return text + " {\n" + members.joined(separator: "\n") + (members.isEmpty ? "" : "\n") + "\(p)}"
    }

    private func enumeration(_ decl: EnumDecl, indent: Int) -> String {
        let p = pad(indent)
        var inherited: [String] = []
        if let raw = decl.rawType { inherited.append(raw.description) }
        inherited += decl.conformances
        var text = "\(p)enum \(decl.name)" + (inherited.isEmpty ? "" : ": " + inherited.joined(separator: ", ")) + " {\n"
        for enumCase in decl.cases {
            var line = "\(pad(indent + 1))case \(enumCase.name)"
            if !enumCase.associated.isEmpty {
                line += "(" + enumCase.associated.map { value in
                    (value.label.map { "\($0): " } ?? "") + value.type.description
                }.joined(separator: ", ") + ")"
            }
            if let raw = enumCase.rawValue { line += " = \(expression(raw))" }
            text += line + "\n"
        }
        return text + "\(p)}"
    }

    // MARK: Patterns

    private func pattern(_ pattern: Pattern) -> String {
        switch pattern {
        case .wildcard: "_"
        case .binding(let name, let mutable): "\(mutable ? "var" : "let") \(name)"
        case .enumCase(let type, let name, let arguments):
            "\(type ?? "").\(name)" + (arguments.map { arguments in
                "(" + arguments.map { argument in
                    (argument.label.map { "\($0): " } ?? "") + self.pattern(argument.pattern)
                }.joined(separator: ", ") + ")"
            } ?? "")
        case .expression(let expr): expression(expr)
        }
    }

    // MARK: Expressions

    private func arguments(_ arguments: [Argument]) -> String {
        arguments.map { (argument: Argument) in
            (argument.label.map { "\($0): " } ?? "") + expression(argument.value)
        }.joined(separator: ", ")
    }

    /// An operand of a larger expression: parenthesized unless it is atomic.
    private func operand(_ expr: Expr) -> String {
        switch expr {
        case .binary, .unary, .attempt, .await, .cast, .ifExpression, .annotated, .closure:
            "(\(expression(expr)))"
        default:
            expression(expr)
        }
    }

    private func expression(_ expr: Expr) -> String {
        switch expr {
        case .literal(let value): return literal(value)
        case .string(let parts):
            return "\"" + parts.map { part in
                switch part {
                case .literal(let text): escaped(text)
                case .expression(let inner): "\\(\(expression(inner)))"
                }
            }.joined() + "\""
        case .variable(let name): return name
        case .extended: return "/* a construct from a layer over the core */"
        case .attempt(let inner, let kind):
            let mark = switch kind { case .plain: ""; case .optional: "?"; case .forced: "!" }
            return "try\(mark) \(expression(inner))"
        case .await(let target, let throwing):
            return (throwing ? "try " : "") + "await" + (target.map { " \(operand($0))" } ?? "")
        case .list(let items): return "[" + items.map(expression).joined(separator: ", ") + "]"
        case .record(let entries):
            if entries.isEmpty { return "[:]" }
            return "[" + entries.map { "\(expression($0.key)): \(expression($0.value))" }.joined(separator: ", ") + "]"
        case .closure(let closure): return closureText(closure)
        case .call(let callee, let arguments):
            // A closure last is written after the parentheses, as Swift does.
            if let last = arguments.last, last.label == nil, case .closure(let closure) = last.value {
                let rest = Array(arguments.dropLast())
                return "\(operand(callee))" + (rest.isEmpty ? "" : "(\(self.arguments(rest)))") + " " + closureText(closure)
            }
            return "\(operand(callee))(\(self.arguments(arguments)))"
        case .member(let base, let name): return "\(operand(base)).\(name)"
        case .caseLiteral(let name, let arguments):
            return ".\(name)" + (arguments.map { "(\(self.arguments($0)))" } ?? "")
        case .unary(let op, let inner): return "\(op.rawValue)\(operand(inner))"
        case .binary(let op, let lhs, let rhs): return "\(operand(lhs)) \(op.rawValue) \(operand(rhs))"
        case .index(let base, let index): return "\(operand(base))[\(expression(index))]"
        case .tuple(let elements): return "(\(arguments(elements)))"
        case .annotated(let inner, let type): return "\(operand(inner)) as \(type)"
        case .forceUnwrap(let inner): return "\(operand(inner))!"
        case .optionalMember(let base, let name): return "\(operand(base))?.\(name)"
        case .optionalIndex(let base, let index): return "\(operand(base))?[\(expression(index))]"
        case .chosen(let inner, _): return expression(inner)
        case .bridged: return "/* a bridged call the checker made */"
        case .cast(let inner, let type, let kind):
            let word = switch kind { case .conditional: "as?"; case .forced: "as!"; case .check: "is"; case .upcast: "as" }
            return "\(operand(inner)) \(word) \(type)"
        case .filePath: return "#filePath"
        case .ifExpression(let node): return ifText(node, indent: 0)
        case .keyPath(let root, let path): return "\\\(root ?? "")." + path.joined(separator: ".")
        case .voidValue(let inner): return expression(inner)
        }
    }

    private func closureText(_ closure: ClosureLiteral) -> String {
        let implicit = closure.parameters.allSatisfy { $0.name.hasPrefix("$") }
        let body = lines(closure.body, indent: 1)
        var text = "{"
        if !implicit {
            text += " (\(parameters(closure.parameters, closure: true)))" + (closure.returnType.map { " -> \($0)" } ?? "") + " in"
        }
        if body.count <= 1 { return text + " " + (body.first?.trimmingCharacters(in: .whitespaces) ?? "") + " }" }
        return text + "\n" + body.joined(separator: "\n") + "\n}"
    }

    private func literal(_ value: Value) -> String {
        switch value {
        case .int(let number): "\(number)"
        case .double(let number): number == number.rounded() && abs(number) < 1e15 ? "\(Int(number)).0" : "\(number)"
        case .string(let text): "\"\(escaped(text))\""
        case .bool(let flag): flag ? "true" : "false"
        case .nothing: "nil"
        default: value.debugDescription
        }
    }

    private func escaped(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            default:
                if scalar.value < 0x20 { result += "\\u{\(String(scalar.value, radix: 16))}" } else { result.unicodeScalars.append(scalar) }
            }
        }
        return result
    }
}
