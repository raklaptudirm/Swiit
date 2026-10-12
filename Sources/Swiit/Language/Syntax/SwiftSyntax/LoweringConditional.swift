import SwiftSyntax

extension Lowering {
    // MARK: Conditional compilation

    /// `#if os(macOS) … #elseif … #else … #endif`: the first clause whose
    /// condition holds, read as the statements it holds.
    mutating func conditional(_ node: IfConfigDeclSyntax) throws -> [Statement] {
        for clause in node.clauses {
            if let condition = clause.condition, !(try holds(condition)) { continue }
            guard case .statements(let items)? = clause.elements else {
                if clause.elements == nil { return [] }
                throw unsupported("this kind of '#if'", clause)
            }
            return try items.flatMap { try statement($0.item) }
        }
        return []
    }

    /// Whether a compilation condition holds, as Swift evaluates it for what
    /// Swiit is: this operating system and architecture, Swiit's modules, and
    /// the Swift it is built with.
    private func holds(_ expr: ExprSyntax) throws -> Bool {
        if let node = expr.as(BooleanLiteralExprSyntax.self) { return node.literal.tokenKind == .keyword(.true) }
        // A flag set with `-D`, which Swiit has none of.
        if expr.is(DeclReferenceExprSyntax.self) { return false }
        if let node = expr.as(PrefixOperatorExprSyntax.self), node.operator.text == "!" { return !(try holds(node.expression)) }
        if let node = expr.as(TupleExprSyntax.self), node.elements.count == 1, let only = node.elements.first { return try holds(only.expression) }
        if let node = expr.as(InfixOperatorExprSyntax.self), let op = node.operator.as(BinaryOperatorExprSyntax.self) {
            switch op.operator.text {
            case "&&": return try holds(node.leftOperand) && holds(node.rightOperand)
            case "||": return try holds(node.leftOperand) || holds(node.rightOperand)
            default: break
            }
        }
        if let node = expr.as(FunctionCallExprSyntax.self), let callee = node.calledExpression.as(DeclReferenceExprSyntax.self),
           let argument = node.arguments.first?.expression {
            switch callee.baseName.text {
            case "os": return Lowering.operatingSystem == argument.trimmedDescription
            case "arch": return Lowering.architecture == argument.trimmedDescription
            case "canImport": return Lowering.modules.contains(argument.trimmedDescription)
            case "targetEnvironment", "hasFeature", "hasAttribute", "_runtime", "_ptrauth", "_endian", "_pointerBitWidth": return false
            case "swift", "compiler":
                guard let version = argument.as(PrefixOperatorExprSyntax.self), let wanted = Lowering.version(of: version.expression.trimmedDescription) else {
                    throw unsupported("this version check", node)
                }
                switch version.operator.text {
                case ">=": return !Lowering.swiftVersion.lexicographicallyPrecedes(wanted)
                case "<": return Lowering.swiftVersion.lexicographicallyPrecedes(wanted)
                default: throw unsupported("this version check", node)
                }
            default: break
            }
        }
        throw unsupported("this compilation condition", expr)
    }

    private static func version(of text: String) -> [Int]? {
        let parts = text.split(separator: ".").map { Int($0) }
        return parts.contains(where: { $0 == nil }) ? nil : parts.map { $0! }
    }

    #if os(macOS)
    private static let operatingSystem = "macOS"
    #elseif os(Linux)
    private static let operatingSystem = "Linux"
    #elseif os(Windows)
    private static let operatingSystem = "Windows"
    #else
    private static let operatingSystem = "other"
    #endif

    #if arch(arm64)
    private static let architecture = "arm64"
    #elseif arch(x86_64)
    private static let architecture = "x86_64"
    #else
    private static let architecture = "other"
    #endif

    /// The Swift this was built with, which `#if swift(>=…)` compares to.
    private static let swiftVersion: [Int] = {
        #if compiler(>=6.3)
        return [6, 3]
        #elseif compiler(>=6.2)
        return [6, 2]
        #elseif compiler(>=6.1)
        return [6, 1]
        #else
        return [6, 0]
        #endif
    }()
}
