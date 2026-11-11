import Foundation
import SwiftSyntax
import Synchronization

// The embedding API (Docs/embedding.md): make an interpreter, give it
// functions and values, run source, and get a value or a diagnostic back.

extension Interpreter {
    /// An interpreter with Swift's syntax, the standard library and nothing
    /// else: no processes, no environment, no files. What a script can name
    /// is what the host registers.
    public convenience init(
        host: Interpreter.Host = Interpreter.Host(),
        limits: Interpreter.Limits = Interpreter.Limits()
    ) {
        let counter = OutputCounter()
        func counted(_ sink: OutputSink) -> OutputSink {
            OutputSink(
                write: {
                    counter.add($0.utf8.count); return sink.write($0)
                },
                traits: sink.traits
            )
        }
        self.init(
            host: Interpreter.Host(
                name: host.name,
                output: counted(host.output),
                error: counted(host.error),
                interrupt: host.interrupt,
                startThread: host.startThread
            ),
            outputCounter: counter
        )
        self.limits = limits
        installBuiltinFunctions()
    }

    /// `print("a", 1)`: its arguments, as interpolation shows them, separated
    /// by spaces, then a newline, to the host's output. The one way a script
    /// speaks, since a bare value gives nothing here.
    func installPrint() {
        nonisolated(unsafe) let interpreter = self  // safe: runs holding the interpreter lock
        let print = hostFunction(
            HostSymbol.function(
                name: "print",
                summary: "Writes its arguments to the output, separated by spaces, then a newline.",
                parameters: [
                    Symbol.Parameter(
                        label: nil,
                        name: "items",
                        type: .any,
                        variadic: true,
                        showsByType: true
                    ),
                    Symbol.Parameter(
                        label: "separator",
                        name: "separator",
                        type: .string,
                        defaultValue: .string(" ")
                    ),
                    Symbol.Parameter(
                        label: "terminator",
                        name: "terminator",
                        type: .string,
                        defaultValue: .string("\n")
                    ),
                ],
                returnType: nil,
                call: { arguments in
                    guard case .list(let items)? = arguments["items"]?.storage else {
                        return .nothing
                    }
                    var separator = " ", terminator = "\n"
                    if case .string(let text)? = arguments["separator"]?.storage {
                        separator = text
                    }
                    if case .string(let text)? = arguments["terminator"]?.storage {
                        terminator = text
                    }
                    let line = try items.map { try interpreter.describing($0) }
                        .joined(separator: separator)
                    interpreter.host.output.write(line + terminator)
                    return .nothing
                }
            )
        )
        scopes[0].declare(print, named: "print")
    }

    /// Asks a run in progress to stop, from any thread. It ends with a
    /// `.cancelled` diagnostic; the next `evaluate` starts afresh.
    public func cancel() { cancellation.request() }
}
