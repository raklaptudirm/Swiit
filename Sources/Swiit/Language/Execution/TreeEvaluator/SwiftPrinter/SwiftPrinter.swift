import Foundation

/// Prints the core's tree as Swift source: the form every construct reduces to. It is for golden
/// tests of what a rewrite produces, `--emit-swift`, and later compiling the result with `swiftc`
/// to compare with the interpreter. A construct that only the checker makes, prints as a comment
/// saying so, so printing is total and the gap is visible.
struct SwiftPrinter {
    init() {}

    /// The program as source, one statement a line.
    func source(_ program: Program) -> String {
        lines(program, indent: 0).joined(separator: "\n")
    }

    /// One expression as source.
    func source(_ expr: Expr) -> String {
        expression(expr)
    }
}

extension SwiftPrinter {
    /// The statements of a program, each as the lines it prints as, at `indent`.
    func lines(_ program: Program, indent: Int) -> [String] {
        program.statements.flatMap { statement($0, indent: indent) }
    }

    /// The spaces of `indent` levels.
    func pad(_ indent: Int) -> String { String(repeating: "    ", count: indent) }

    /// A program as a braced block, its statements a level in.
    func block(_ program: Program, indent: Int) -> String {
        let inner = lines(program, indent: indent + 1)
        if inner.isEmpty { return "{}" }
        return "{\n" + inner.joined(separator: "\n") + "\n" + pad(indent) + "}"
    }
}
