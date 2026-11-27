import Foundation

// Expressions as Swift source.

extension SwiftPrinter {
    func arguments(_ arguments: [Argument]) -> String {
        arguments.map { (argument: Argument) in
            (argument.label.map { "\($0): " } ?? "") + expression(argument.value)
        }
        .joined(separator: ", ")
    }

    /// An operand of a larger expression: parenthesized unless it is atomic.
    func operand(_ expr: Expr) -> String {
        switch expr {
        case .binary, .unary, .attempt, .await, .cast, .ifExpression, .annotated, .closure:
            "(\(expression(expr)))"
        default:
            expression(expr)
        }
    }

    /// An expression as source: each kind to the group that prints it, so that every kind is named
    /// here and a new one is a compile error until it is printed.
    func expression(_ expr: Expr) -> String {
        switch expr {
        case .literal, .local, .variable, .string, .filePath, .keyPath:
            return atomText(expr)
        case .member, .index, .subscripted, .indexDefault, .optionalMember, .optionalIndex,
            .optionalSubscripted, .forceUnwrap:
            return accessText(expr)
        case .unary, .binary, .cast, .annotated, .attempt, .await:
            return operationText(expr)
        case .call, .caseLiteral, .closure, .childTask, .bridged:
            return callText(expr)
        case .list, .record, .tuple:
            return collectionText(expr)
        case .ifExpression(let node):
            return ifText(node, indent: 0)
        // What only says more of another: it prints as that one.
        case .chosen(let inner, _), .specialized(let inner, _), .voidValue(let inner),
            .described(let inner, _):
            return expression(inner)
        case .inoutArgument(let inner):
            return "&" + operand(inner)
        }
    }

    /// A name, a literal, text with interpolations, a key path or `#filePath`.
    func atomText(_ expr: Expr) -> String {
        switch expr {
        case .literal(let value): return literal(value)
        case .local(let local): return local.name
        case .string(let parts):
            return "\""
                + parts.map { part in
                    switch part {
                    case .literal(let text): escaped(text)
                    case .expression(let inner): "\\(\(expression(inner)))"
                    }
                }
                .joined() + "\""
        case .variable(let name): return name
        case .filePath: return "#filePath"
        case .keyPath(let root, let path): return "\\\(root ?? "")." + path.joined(separator: ".")
        default: preconditionFailure("not of this group")
        }
    }

    /// A member, an index or a subscript of a value, optional or forced.
    func accessText(_ expr: Expr) -> String {
        switch expr {
        case .member(let base, let name): return "\(operand(base)).\(name)"
        case .index(let base, let index): return "\(operand(base))[\(expression(index))]"
        case .subscripted(let base, let list): return "\(operand(base))[\(arguments(list))]"
        case .indexDefault(let base, let key, let fallback):
            return "\(operand(base))[\(expression(key)), default: \(expression(fallback))]"
        case .forceUnwrap(let inner): return "\(operand(inner))!"
        case .optionalMember(let base, let name): return "\(operand(base))?.\(name)"
        case .optionalIndex(let base, let index): return "\(operand(base))?[\(expression(index))]"
        case .optionalSubscripted(let base, let list):
            return "\(operand(base))?[\(arguments(list))]"
        default: preconditionFailure("not of this group")
        }
    }

    /// An operator, a cast, a type annotation, `try` or `await`.
    func operationText(_ expr: Expr) -> String {
        switch expr {
        case .attempt(let inner, let kind):
            let mark =
                switch kind {
                case .plain: ""
                case .optional: "?"
                case .forced: "!"
                }
            return "try\(mark) \(expression(inner))"
        case .await(let target, let throwing):
            return (throwing ? "try " : "") + "await \(operand(target))"
        case .unary(let op, let inner): return "\(op.rawValue)\(operand(inner))"
        case .binary(let op, let lhs, let rhs):
            return "\(operand(lhs)) \(op.rawValue) \(operand(rhs))"
        case .annotated(let inner, let type): return "\(operand(inner)) as \(type)"
        case .cast(let inner, let type, let kind):
            let word =
                switch kind {
                case .conditional: "as?"
                case .forced: "as!"
                case .check: "is"
                case .upcast: "as"
                }
            return "\(operand(inner)) \(word) \(type)"
        default: preconditionFailure("not of this group")
        }
    }

    /// A call, a case of an enum, a closure, a child task, or a Swift member the checker chose.
    func callText(_ expr: Expr) -> String {
        switch expr {
        case .closure(let closure): return closureText(closure)
        case .childTask(let closure): return "Task " + closureText(closure)
        case .call(let callee, let arguments):
            // A closure last is written after the parentheses, as Swift does.
            if let last = arguments.last, last.label == nil, case .closure(let closure) = last.value
            {
                let rest = Array(arguments.dropLast())
                return "\(operand(callee))" + (rest.isEmpty ? "" : "(\(self.arguments(rest)))")
                    + " "
                    + closureText(closure)
            }
            return "\(operand(callee))(\(self.arguments(arguments)))"
        case .caseLiteral(let name, let arguments):
            return ".\(name)" + (arguments.map { "(\(self.arguments($0)))" } ?? "")
        // A Swift member the checker chose: the call it is.
        case .bridged(let type, let index, let receiver, let args):
            guard let members = Bridge.current[type]?.lowered, members.indices.contains(index)
            else {
                return "/* a bridged call the checker made */"
            }
            let member = members[index]
            let base = receiver.map(operand) ?? type
            switch member.kind {
            case .property: return "\(base).\(member.name)"
            case .initializer: return "\(type)(\(arguments(args)))"
            case .method, .setter:
                return expression(.call(.member(.variable(base), member.name), args))
            }
        default: preconditionFailure("not of this group")
        }
    }

    /// A list, a dictionary or a tuple.
    func collectionText(_ expr: Expr) -> String {
        switch expr {
        case .list(let items): return "[" + items.map(expression).joined(separator: ", ") + "]"
        case .record(let entries):
            if entries.isEmpty { return "[:]" }
            return "["
                + entries.map { "\(expression($0.key)): \(expression($0.value))" }
                .joined(separator: ", ") + "]"
        case .tuple(let elements): return "(\(arguments(elements)))"
        default: preconditionFailure("not of this group")
        }
    }

    func closureText(_ closure: ClosureLiteral) -> String {
        let implicit = closure.parameters.allSatisfy { $0.name.hasPrefix("$") }
        let body = lines(closure.body, indent: 1)
        var text = "{"
        if !implicit {
            text +=
                " (\(parameters(closure.parameters, closure: true)))"
                + (closure.returnType.map { " -> \($0)" } ?? "")
                + " in"
        }
        if body.count <= 1 {
            return text + " " + (body.first?.trimmingCharacters(in: .whitespaces) ?? "") + " }"
        }
        return text + "\n" + body.joined(separator: "\n") + "\n}"
    }

    func literal(_ value: Value) -> String {
        switch value.storage {
        case .int(let number): "\(number)"
        case .double(let number):
            number == number.rounded() && abs(number) < 1e15 ? "\(Int(number)).0" : "\(number)"
        case .string(let text): "\"\(escaped(text))\""
        case .bool(let flag): flag ? "true" : "false"
        case .nothing: "nil"
        default: value.debugDescription
        }
    }

    func escaped(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            default:
                if scalar.value < 0x20 {
                    result += "\\u{\(String(scalar.value, radix: 16))}"
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }
}
