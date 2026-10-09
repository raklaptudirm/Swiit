import SwishKit

/// Syntax the core's grammar doesn't define: what a layer over the core adds,
/// like the shell's commands, pipelines and substitutions. The tree holds it
/// without knowing what it is, and each pass asks it to do its part: the
/// checker to check it, the interpreter to run it. The core never names the
/// node types, so it can be built without them (Docs/Design/frontend.md).
@_spi(Shell) public protocol SyntaxExtension: Sendable {
    /// Trees compare, so extensions do.
    func isEqual(to other: any SyntaxExtension) -> Bool
}

extension SyntaxExtension where Self: Equatable {
    @_spi(Shell) public func isEqual(to other: any SyntaxExtension) -> Bool {
        (other as? Self) == self
    }
}

/// An expression an extension adds: `$(…)`, `$name`, `async …`.
@_spi(Shell) public protocol ExprExtension: SyntaxExtension {
    /// Checks it, with whatever the checker found written in, and gives its type.
    mutating func check(in checker: TypeChecker, expecting expected: TypeAnnotation?) throws -> TypeAnnotation
    func evaluate(in interpreter: Interpreter) throws -> Value
}

/// A unit an extension adds: a command or a pipeline of them. A unit has an
/// exit status, which `&&`, `||` and conditions go by.
@_spi(Shell) public protocol UnitExtension: SyntaxExtension {
    mutating func check(in checker: TypeChecker) throws
    func run(in interpreter: Interpreter, context: UnitContext) throws -> Int32
    /// Whether it ends the program (`exit`), for a function that must return
    /// on every path.
    var leavesProgram: Bool { get }
}

extension UnitExtension {
    @_spi(Shell) public var leavesProgram: Bool { false }
}

/// A statement an extension adds: `env.NAME = value`, `import Name from path`.
@_spi(Shell) public protocol StatementExtension: SyntaxExtension {
    mutating func check(in checker: TypeChecker) throws
    func run(in interpreter: Interpreter) throws -> Int32
}

/// What the tree holds for each: the node, compared through `isEqual`.
@_spi(Shell) public struct ExprExtensionBox: Equatable, Sendable {
    @_spi(Shell) public var node: any ExprExtension

    @_spi(Shell) public init(_ node: any ExprExtension) {
        self.node = node
    }

    @_spi(Shell) public static func == (lhs: ExprExtensionBox, rhs: ExprExtensionBox) -> Bool {
        lhs.node.isEqual(to: rhs.node)
    }
}

@_spi(Shell) public struct UnitExtensionBox: Equatable, Sendable {
    @_spi(Shell) public var node: any UnitExtension

    @_spi(Shell) public init(_ node: any UnitExtension) {
        self.node = node
    }

    @_spi(Shell) public static func == (lhs: UnitExtensionBox, rhs: UnitExtensionBox) -> Bool {
        lhs.node.isEqual(to: rhs.node)
    }
}

@_spi(Shell) public struct StatementExtensionBox: Equatable, Sendable {
    @_spi(Shell) public var node: any StatementExtension

    @_spi(Shell) public init(_ node: any StatementExtension) {
        self.node = node
    }

    @_spi(Shell) public static func == (lhs: StatementExtensionBox, rhs: StatementExtensionBox) -> Bool {
        lhs.node.isEqual(to: rhs.node)
    }
}
