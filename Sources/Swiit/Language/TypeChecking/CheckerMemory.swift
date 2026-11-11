import Foundation

/// What the checker remembers from the entries it has already checked, so a later entry is checked
/// against them: the interpreter holds one for as long as it lives, and only the checker reads it.
struct CheckerMemory {
    /// The declared types of globals, so a later entry knows `let xs: [Int] = []` is an `[Int]`.
    var globalTypes: [String: TypeAnnotation] = [:]

    /// For each function, the functions declared at the prompt that call it without `await`, for
    /// the redefinition rule (TypeChecker+Effects.swift).
    var unawaitedCallers: [String: Set<String>] = [:]

    /// Replaces what was recorded for these callers with the calls they make now: what a program
    /// declares replaces what was declared before.
    mutating func record(unawaitedCalls: [String: Set<String>]) {
        for caller in unawaitedCalls.keys {
            for callee in unawaitedCallers.keys {
                unawaitedCallers[callee]?.remove(caller)
            }
        }

        for (caller, callees) in unawaitedCalls {
            for callee in callees {
                unawaitedCallers[callee, default: []].insert(caller)
            }
        }
    }
}
