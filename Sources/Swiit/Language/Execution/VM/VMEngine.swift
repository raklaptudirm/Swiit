import Foundation

/// How a function body runs: on the tree evaluator, or compiled to `Code` and run by the VM where the
/// compiler handles it (`Docs/vm.md`). Both run the same checked program and give the same results.
enum Engine: Sendable {
    case tree
    case vm

    /// The engine a new interpreter starts with: the VM. Building with `-Xswiftc -DSWIIT_TREE_ENGINE`
    /// makes it the tree evaluator, which runs the test suites as the reference.
    static var initial: Engine {
        #if SWIIT_TREE_ENGINE
        .tree
        #else
        .vm
        #endif
    }
}

/// What the VM made of a function body, kept with the function.
enum VMCode {
    case untried
    case code(Code)
    /// It stays on the tree evaluator, for this reason.
    case unsupported(String)
}

extension Function {
    /// An initializer, which the checker names with its type's (`Point.init`).
    var isInitializer: Bool { name == "init" || name?.hasSuffix(".init") == true }

    /// Whether the compiler may take this body: a function or method, or a closure with what it
    /// captured, whose parameters are taken as they come.
    var isCompilable: Bool {
        guard case .swiit(let program) = body else { return false }
        return program.frameSize != nil && !(name != nil && captured.count > 2)
    }
}
