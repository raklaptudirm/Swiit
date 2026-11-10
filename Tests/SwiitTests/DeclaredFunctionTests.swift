import Foundation
import Swiit
import Testing

// Functions a host declares in Swift source: what they call and what their defaults name.

private final class Log: @unchecked Sendable {
    var text = ""
}

private func interpreter(
    limits: Interpreter.Limits = Interpreter.Limits(),
    log: Log = Log()
) -> Interpreter {
    Interpreter(
        host: Interpreter.Host(
            output: OutputSink({
                log.text += $0; return true
            }),
            error: OutputSink({
                log.text += "err: " + $0; return true
            })
        ),
        limits: limits
    )
}

extension Value {
    /// The entry named `name` of a structured value.
    fileprivate func entry(_ name: String) -> Value? {
        Mirror(reflecting: self).children.first { $0.label == name }?.value as? Value
    }

    /// What a host reads of a value's shape and children, as it would of any Swift value.
    fileprivate var mirror: Mirror { Mirror(reflecting: self) }
}

@Test func aHostDeclaresWhatItAddsToTheLanguage() throws {
    let swiit = interpreter()
    try swiit.declare(
        """
        /// A counter the host runs.
        struct Counter {
            let start: Int
            func next() -> Int
        }

        extension Sequence {
            /// Keeps the first of each.
            func firsts(_ count: Int) -> [Any]
        }

        extension Int {
            var doubled: Int { self * 2 }
        }

        /// Says hello.
        func hello(_ name: String) -> String
        """,
        bodies: [
            "Counter.next": { arguments in
                Value(
                    (arguments["self"]?.entry("start").flatMap { $0.casting(to: Int.self) }
                        ?? 0) + 1
                )
            },
            "Sequence.firsts": { arguments in
                // A sequence's items, one at a time, as far as are wanted.
                let wanted = arguments["count"]?.casting(to: Int.self) ?? 0
                guard let value = arguments["self"], let items = try? AnySequence<Value>(value)
                else {
                    return Value([] as [Value])
                }
                return Value(Array(items.prefix(wanted)))
            },
            "hello": { arguments in Value("hello, " + (arguments["name"]?.description ?? "")) },
        ]
    )
    #expect(try swiit.evaluate("Counter(start: 4).next()") == 5)
    #expect(try swiit.evaluate("[7, 8, 9].firsts(2)") == [7, 8])
    #expect(try swiit.evaluate("3.doubled") == 6)
    #expect(try swiit.evaluate(#"hello("you")"#) == "hello, you")
    // What the host declared is the host's.
    #expect(swiit.globals(named: "hello").first?.isBuiltin == true)
    #expect(!ScriptType.list(.int).members(named: "firsts", in: swiit).isEmpty)
}

@Test func aDeclaredFunctionCallsWhatTheProgramDefined() throws {
    let swiit = interpreter()
    _ = try swiit.evaluate("func helper() -> Int { 41 }")
    try swiit.declare("func caller() -> Int { helper() + 1 }")
    #expect(try swiit.evaluate("caller()") == Value(42))
}

@Test func aDeclaredFunctionCallsAHostFunction() throws {
    let swiit = interpreter()
    swiit.register("hostAnswer") { () -> Int in 42 }
    try swiit.declare("func answer() -> Int { hostAnswer() }")
    #expect(try swiit.evaluate("answer()") == Value(42))
}

@Test func aDeclaredFunctionsDefaultNamesACaseOfTheProgramsEnum() throws {
    let swiit = interpreter()
    _ = try swiit.evaluate("enum Where { case here, there }")
    try swiit.declare(#"func place(_ w: Where = .here) -> String { "\(w)" }"#)
    #expect(try swiit.evaluate("place()") == Value("here"))
    #expect(try swiit.evaluate("place(.there)") == Value("there"))
}

@Test func aDeclaredFunctionNamesWhatItCallsWhenItIsDeclared() throws {
    let swiit = interpreter()
    #expect(throws: Diagnostic.self) {
        try swiit.declare("func caller() -> Int { missing() }")
    }
}
