import Testing

@testable import Swiit

// What the VM tests share: running a program on an engine, and what is observable of it.

final class VMLog: @unchecked Sendable {
    var text = ""
}

struct VMOutcome: Equatable {
    static func describe(_ error: Diagnostic) -> String {
        "\(error.kind)|\(error.message)|\(String(describing: error.range))"
    }

    var value: String
    /// Everything of the diagnostic, as text: two interpreters' enum types are not equal as values.
    var failure: String?
    var output: String
}

func vmRun(
    _ source: String,
    on engine: Engine,
    limits: Interpreter.Limits = .init()
)
    -> (outcome: VMOutcome, swiit: Interpreter)
{
    let log = VMLog()
    let swiit = Interpreter(
        host: Interpreter.Host(
            output: OutputSink({
                log.text += $0
                return true
            }),
            error: OutputSink({
                log.text += "err: " + $0
                return true
            })
        ),
        limits: limits
    )
    swiit.engine = engine
    do {
        let value = try swiit.evaluate(source)
        return (VMOutcome(value: value.description, failure: nil, output: log.text), swiit)
    } catch {
        return (
            VMOutcome(value: "", failure: VMOutcome.describe(error), output: log.text), swiit
        )
    }
}

/// The functions of the program named that the VM did not compile, each with why.
func vmCompiled(_ names: [String], in swiit: Interpreter) -> [String] {
    names.compactMap { name in
        guard case .function(let callable)? = swiit.lookup(name)?.value.storage else {
            return "\(name): not a function"
        }
        let function = (callable as? Function) ?? (callable as? OverloadSet)?.candidates.first
        switch function?.vmCode {
        case .code?: return nil
        case .unsupported(let reason)?: return "\(name): \(reason)"
        default: return "\(name): never run"
        }
    }
}

/// How many nodes the compiled functions named hand to the tree evaluator, all together.
func vmTreeNodes(_ names: [String], in swiit: Interpreter) -> Int {
    names.reduce(0) { total, name in
        guard case .function(let callable)? = swiit.lookup(name)?.value.storage else {
            return total
        }
        let function = (callable as? Function) ?? (callable as? OverloadSet)?.candidates.first
        guard case .code(let code)? = function?.vmCode else { return total }
        return total + code.trees.count
    }
}

/// How many steps a program takes: the fewest that let it finish.
func vmSteps(_ source: String, on engine: Engine) -> Int {
    var low = 1
    var high = 1 << 20
    while low < high {
        let middle = (low + high) / 2
        if vmRun(source, on: engine, limits: .init(maxSteps: middle)).outcome.failure == nil {
            high = middle
        } else {
            low = middle + 1
        }
    }
    return low
}

struct VMSample {
    let name: String
    let source: String
    /// The functions in it the compiler is expected to take.
    let compiles: [String]
    /// Every function of it that runs is compiled: the VM left none to the tree evaluator.
    var entirely = false
    /// How many loops of the program's own code the VM runs.
    var loops = 0
    /// How many expressions and statements the functions in `compiles` leave to the tree evaluator,
    /// where the sample says.
    var trees: Int?
    /// How many times the tree evaluator runs a piece of what the compiler took, where the sample says:
    /// what the fast paths decline.
    var treeRuns: Int?
    /// At least how many calls of closures a native body made are run as leaves, where the sample says.
    var leafCalls: Int?
}
