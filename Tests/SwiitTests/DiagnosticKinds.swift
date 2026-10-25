import Swiit

// What a test says of a diagnostic's kind, where the kind carries something.
extension Diagnostic {
    var isRuntime: Bool { if case .runtime = kind { true } else { false } }
    var isSyntax: Bool { if case .syntax = kind { true } else { false } }
    var isFatal: Bool { if case .fatal = kind { true } else { false } }
}
