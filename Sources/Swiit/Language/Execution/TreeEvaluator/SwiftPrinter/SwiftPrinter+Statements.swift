import Foundation

// Statements as Swift source: declarations of values, assignments, control flow and errors.

extension SwiftPrinter {
    /// A statement as the lines it prints as.
    func statement(_ statement: Statement, indent: Int) -> [String] {
        let p = pad(indent)
        switch statement {
        case .declare(let name, let mutable, let value):
            return declarationText(name, mutable: mutable, value, indent: indent)
        case .declareLocal(let local, let mutable, let value):
            return declarationText(local.name, mutable: mutable, value, indent: indent)
        case .assign(let assignment):
            return assignmentText(assignment, indent: indent)
        case .function(let decl):
            return documentation(decl.documentation).map { "\(p)/// \($0)" } + [
                p + function(decl, keyword: "func", indent: indent)
            ]
        case .doCatch(let body, let clauses):
            return doCatchText(body, clauses, indent: indent)
        case .throwStatement(let value):
            return ["\(p)throw \(expression(value))"]
        case .enumDecl(let decl):
            return [enumeration(decl, indent: indent)]
        case .typeExtension(let decl):
            return [typeExtension(decl, indent: indent)]
        case .operatorDeclaration(_, let source):
            return [p + source]
        case .classDecl(let decl):
            return classText(decl, indent: indent)
        case .protocolDecl(let decl):
            return protocolText(decl, indent: indent)
        case .structDecl(let decl):
            return [structure(decl, indent: indent)]
        case .extensionDecl(let name, let methods):
            return methodsText(name, methods, indent: indent)
        case .deferBlock(let body):
            return ["\(p)defer \(block(body, indent: indent))"]
        case .fallthroughStatement:
            return ["\(p)fallthrough"]
        case .returnStatement(let value):
            return [value.map { "\(p)return \(expression($0))" } ?? "\(p)return"]
        case .guardStatement(let condition, let otherwise, _):
            return [
                "\(p)guard \(conditionText(condition)) else \(block(otherwise, indent: indent))"
            ]
        case .breakStatement(let label):
            return ["\(p)break" + (label.map { " \($0)" } ?? "")]
        case .continueStatement(let label):
            return ["\(p)continue" + (label.map { " \($0)" } ?? "")]
        case .expression(let expr):
            return [p + expression(expr)]
        case .ifStatement(let node):
            return [p + ifText(node, indent: indent)]
        case .switchStatement(let node):
            return switchText(node, indent: indent)
        case .forLoop(let loop):
            return forText(loop, indent: indent)
        case .whileLoop(let loop):
            return whileText(loop, indent: indent)
        }
    }

    /// `let` and `var`, and `async let` for a child task.
    func declarationText(_ name: String, mutable: Bool, _ value: Expr, indent: Int) -> [String] {
        let p = pad(indent)
        let keyword = mutable ? "var" : "let"
        if case .childTask(let closure) = value,
            case .expression(let inner)? = closure.body.statements.first
        {
            return ["\(p)async let \(name) = \(expression(inner))"]
        }
        if case .annotated(let inner, let type) = value {
            return ["\(p)\(keyword) \(name): \(type) = \(expression(inner))"]
        }
        return ["\(p)\(keyword) \(name) = \(expression(value))"]
    }

    /// An assignment, through the path of its target.
    func assignmentText(_ assignment: Assignment, indent: Int) -> [String] {
        let p = pad(indent)
        var target = assignment.root
        for step in assignment.path {
            switch step {
            case .member(let name): target += ".\(name)"
            case .index(let index): target += "[\(expression(index))]"
            case .indexDefault(let key, let fallback):
                target += "[\(expression(key)), default: \(expression(fallback))]"
            case .subscripted(let list): target += "[\(arguments(list))]"
            case .unwrap: target += "!"
            case .optionalChain: target += "?"
            }
        }
        let op = assignment.op.map { "\($0.rawValue)=" } ?? "="
        return ["\(p)\(target) \(op) \(expression(assignment.value))"]
    }

    /// `do` and its `catch` clauses.
    func doCatchText(_ body: Program, _ clauses: [SwitchCase], indent: Int) -> [String] {
        let p = pad(indent)
        var text = "\(p)do \(block(body, indent: indent))"
        for clause in clauses {
            text += " catch "
            if let pattern = clause.patterns.first { text += self.pattern(pattern) + " " }
            if let guardExpr = clause.guardExpr { text += "where \(expression(guardExpr)) " }
            text += block(clause.body, indent: indent)
        }
        return [text]
    }

    /// `switch` and its cases.
    func switchText(_ node: SwitchStatement, indent: Int) -> [String] {
        let p = pad(indent)
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
            text +=
                (inner.isEmpty ? [pad(indent + 1) + "break"] : inner).joined(separator: "\n")
                + "\n"
        }
        return [p + text + "\(p)}"]
    }

    /// `for … in`.
    func forText(_ loop: ForLoop, indent: Int) -> [String] {
        let p = pad(indent)
        let effects = (loop.isTry ? "try " : "") + (loop.isAwait ? "await " : "")
        return [
            p + labelText(loop.label)
                + "for \(effects)\(loopPattern(loop.pattern)) in \(expression(loop.sequence)) \(block(loop.body, indent: indent))"
        ]
    }

    /// `while` and `repeat … while`.
    func whileText(_ loop: WhileLoop, indent: Int) -> [String] {
        let p = pad(indent)
        if loop.isRepeat {
            return [
                p + labelText(loop.label)
                    + "repeat \(block(loop.body, indent: indent)) while \(expression(loop.condition))"
            ]
        }
        return [
            p + labelText(loop.label)
                + "while \(expression(loop.condition)) \(block(loop.body, indent: indent))"
        ]
    }

    func ifText(_ node: IfStatement, indent: Int) -> String {
        var text = "if \(conditionText(node.condition)) \(block(node.then, indent: indent))"
        if let otherwise = node.otherwise {
            // `else if`: an else holding only an `if`.
            if otherwise.statements.count == 1,
                case .ifStatement(let nested) = otherwise.statements[0]
            {
                text += " else " + ifText(nested, indent: indent)
            } else {
                text += " else \(block(otherwise, indent: indent))"
            }
        }
        return text
    }

    func conditionText(_ condition: IfStatement.Condition) -> String {
        switch condition {
        case .expression(let expr): expression(expr)
        case .binding(let name, let mutable, let value):
            "\(mutable ? "var" : "let") \(name) = \(expression(value))"
        case .pattern(let p, let value): "case \(pattern(p)) = \(expression(value))"
        }
    }
}
