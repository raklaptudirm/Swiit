import Foundation
import SwiitKit

extension Interpreter {
    /// Functions Swift's standard library has at the top level, which aren't
    /// members of a type, so the bridge has no type to put them on.
    func installLanguageFunctions() {
        nonisolated(unsafe) let interpreter = self
        func declare(_ export: ExportedFunction) {
            scopes[0].declare(hostFunction(export), named: export.name)
        }
        let condition = ExportedParameter(label: nil, name: "condition", type: .bool)
        let message = ExportedParameter(label: nil, name: "message", type: .string, defaultValue: .string(""))
        for (name, summary) in [("assert", "Stops with the message unless the condition holds."),
                                ("precondition", "Stops with the message unless the condition holds.")] {
            declare(ExportedFunction(
                name: name, summary: summary, parameters: [condition, message], returnType: nil, isThrowing: false,
                call: { arguments in
                    guard case .bool(true)? = arguments["condition"] else {
                        let text = arguments["message"].map { "\($0)" } ?? ""
                        throw RuntimeError("\(name == "assert" ? "Assertion" : "Precondition") failed" + (text.isEmpty ? "" : ": \(text)"))
                    }
                    return .nothing
                }
            ))
        }
        declare(ExportedFunction(
            name: "fatalError", summary: "Stops with the message.",
            parameters: [message], returnType: nil, isThrowing: false,
            call: { arguments in
                let text = arguments["message"].map { "\($0)" } ?? ""
                throw RuntimeError("Fatal error" + (text.isEmpty ? "" : ": \(text)"))
            }
        ))
        // `zip(a, b)`: pairs of what two sequences hold, as far as the shorter goes. Swift's
        // lazy `Zip2Sequence` is held as the array it would give.
        declare(ExportedFunction(
            name: "zip", summary: "Pairs of the items of two sequences, up to the end of the shorter.",
            parameters: [ExportedParameter(label: nil, name: "first", type: .any), ExportedParameter(label: nil, name: "second", type: .any)],
            returnType: .list(.any), isThrowing: false,
            call: { arguments in
                func items(_ value: Value?) throws -> AnyIterator<Value> {
                    guard let value else { return AnyIterator { nil } }
                    if case .string(let text) = value { return AnyIterator(text.lazy.map { .string(String($0)) }.makeIterator()) }
                    guard let items = Interpreter.items(of: value) else { throw RuntimeError("zip can't read a \(value.typeName)") }
                    return items
                }
                var first = try items(arguments["first"])
                var second = try items(arguments["second"])
                var pairs: [Value] = []
                while let a = first.next(), let b = second.next() {
                    try interpreter.checkInterrupt()
                    pairs.append(.record(Record(["0": a, "1": b])))
                }
                return .list(pairs)
            }
        ))
        // `stride(from:to:by:)` and `stride(from:through:by:)`, for Int and Double.
        for (end, inclusive) in [("to", false), ("through", true)] {
            for (type, name) in [(SwiitType.int, "Int"), (SwiitType.double, "Double")] {
                declare(ExportedFunction(
                    name: "stride", summary: "The values from `from` to `\(end)` `\(end == "to" ? "(not including it)" : "")`, `by` apart, as \(name)s.",
                    parameters: [ExportedParameter(label: "from", name: "from", type: type),
                                 ExportedParameter(label: end, name: end, type: type),
                                 ExportedParameter(label: "by", name: "by", type: type)],
                    returnType: .list(type), isThrowing: false,
                    call: { arguments in
                        guard let start = arguments["from"], let stop = arguments[end], let step = arguments["by"] else { return .list([]) }
                        if case .int(let a) = start, case .int(let b) = stop, case .int(let s) = step {
                            guard s != 0 else { throw RuntimeError("stride: the step can't be 0") }
                            var values: [Value] = []
                            var current = a
                            while s > 0 ? (inclusive ? current <= b : current < b) : (inclusive ? current >= b : current > b) {
                                try interpreter.checkInterrupt()
                                values.append(.int(current))
                                let (next, overflow) = current.addingReportingOverflow(s)
                                if overflow { break }
                                current = next
                            }
                            return .list(values)
                        }
                        guard let a = start.asDouble, let b = stop.asDouble, let s = step.asDouble else { return .list([]) }
                        guard s != 0 else { throw RuntimeError("stride: the step can't be 0") }
                        var values: [Value] = []
                        var index = 0.0
                        while true {
                            let current = a + index * s
                            guard s > 0 ? (inclusive ? current <= b : current < b) : (inclusive ? current >= b : current > b) else { break }
                            try interpreter.checkInterrupt()
                            values.append(.double(current))
                            index += 1
                        }
                        return .list(values)
                    }
                ))
            }
        }
    }
}
