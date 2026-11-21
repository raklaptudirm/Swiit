import Foundation
import Testing

@testable import Swiit

// What Swiit does with Swift code, one row for each feature: a snippet and what it does today. Each row
// is run, so a feature that starts to work fails its row until the status is updated. The table also
// writes the "Swift support" article of the documentation (`SWIIT_WRITE_SUPPORT=1 swift test --filter
// theSupportArticleIsCurrent`), and a test fails when the committed article is not what the table says.

/// What a feature does in Swiit, against the Swift compiler.
private enum Support: String {
    /// Runs, with the result the row says.
    case works = "Works"
    /// Rejected with a diagnostic, as the Swift compiler rejects it.
    case rejectedLikeSwift = "Rejected, as in Swift"
    /// Rejected with a diagnostic, though Swift accepts it.
    case missing = "Not supported"
    /// Runs, though the Swift compiler rejects it.
    case acceptsWhatSwiftRejects = "Runs; Swift rejects it"
}

private struct Row: Sendable, CustomTestStringConvertible {
    let area: String
    let feature: String
    let support: Support
    /// A program whose last expression is its result, or nil for a row the table only states.
    let source: String?
    /// The result's description, for a row that works.
    let result: String?
    let note: String

    var testDescription: String { "\(area): \(feature)" }

    init(
        _ area: String,
        _ feature: String,
        _ support: Support,
        _ source: String? = nil,
        gives result: String? = nil,
        _ note: String = ""
    ) {
        self.area = area
        self.feature = feature
        self.support = support
        self.source = source
        self.result = result
        self.note = note
    }
}

private let tasks = "Tasks and groups"
private let isolation = "Actors and isolation"
private let streams = "Streams, continuations and executors"
private let language = "Language"
private let host = "Host boundary"
private let model = "Execution model"

private let rows: [Row] = [
    // MARK: Tasks and groups
    Row(
        tasks,
        "`Task { }` and `value`",
        .works,
        "let t = Task { 21 * 2 }\nawait t.value",
        gives: "42"
    ),
    Row(
        tasks,
        "`cancel()` and the cancellation error",
        .works,
        """
        let t = Task { try await Task.sleep(nanoseconds: 10_000_000_000); return 1 }
        t.cancel()
        var r = false
        do { _ = try await t.value } catch { r = true }
        r
        """,
        gives: "true"
    ),
    Row(tasks, "`Task.isCancelled`", .works, "Task.isCancelled", gives: "false"),
    Row(tasks, "`Task.checkCancellation()`", .works, "try Task.checkCancellation()\n1", gives: "1"),
    Row(tasks, "`Task.yield()`", .works, "await Task.yield()\n1", gives: "1"),
    Row(
        tasks,
        "`Task.sleep(nanoseconds:)`",
        .works,
        "try await Task.sleep(nanoseconds: 1000)\n1",
        gives: "1"
    ),
    Row(
        tasks,
        "`withTaskGroup`",
        .works,
        """
        let s = await withTaskGroup(of: Int.self) { g in
            for i in 1...3 { g.addTask { i } }
            var t = 0
            for await v in g { t += v }
            return t
        }
        s
        """,
        gives: "6"
    ),
    Row(
        tasks,
        "`withThrowingTaskGroup`",
        .works,
        """
        let s = try await withThrowingTaskGroup(of: Int.self) { g in
            g.addTask { 1 }
            var t = 0
            for try await v in g { t += v }
            return t
        }
        s
        """,
        gives: "1"
    ),
    Row(
        tasks,
        "`cancelAll()` and `isCancelled` of a group",
        .works,
        "await withTaskGroup(of: Int.self) { g in g.cancelAll(); return g.isCancelled }",
        gives: "true"
    ),
    Row(
        tasks,
        "`async let`",
        .works,
        "func f() async -> Int { 5 }\nasync let a = f()\nasync let b = f()\nawait a + b",
        gives: "10"
    ),
    Row(
        tasks,
        "Reading an `async let` without `await`",
        .rejectedLikeSwift,
        "func f() async -> Int { 5 }\nasync let a = f()\na"
    ),
    Row(
        tasks,
        "`await` outside an async function",
        .rejectedLikeSwift,
        "func f() async -> Int { 1 }\nfunc g() -> Int { await f() }"
    ),
    Row(
        tasks,
        "An `async` closure",
        .works,
        "let f: () async -> Int = { 1 }\nawait f()",
        gives: "1"
    ),
    Row(
        tasks,
        "`Task.sleep(for:)` and `Duration`",
        .missing,
        "try await Task.sleep(for: .milliseconds(1))\n1"
    ),
    Row(tasks, "`Task.detached`", .missing, "let t = Task.detached { 7 }\nawait t.value"),
    Row(tasks, "`Task(priority:)`", .missing, "let t = Task(priority: .high) { 1 }\nawait t.value"),
    Row(tasks, "`Task.currentPriority`", .missing, "Task.currentPriority"),
    Row(
        tasks,
        "`withDiscardingTaskGroup`",
        .missing,
        "await withDiscardingTaskGroup { g in g.addTask { } }\n1"
    ),
    Row(
        tasks,
        "Task-local values",
        .missing,
        "enum E { @TaskLocal static var x = 1 }\nE.$x.withValue(5) { E.x }",
        "`@TaskLocal` is not read."
    ),

    // MARK: Actors and isolation
    Row(
        isolation,
        "`actor` declarations",
        .works,
        "actor C { var n = 0; func inc() { n += 1 }; func get() -> Int { n } }\nlet c = C()\nawait c.inc()\nawait c.get()",
        gives: "1"
    ),
    Row(
        isolation,
        "Reading an actor's state without `await`",
        .rejectedLikeSwift,
        "actor C { var n = 0 }\nlet c = C()\nc.n"
    ),
    Row(
        isolation,
        "`nonisolated` members",
        .works,
        "actor C { nonisolated func hi() -> Int { 1 } }\nC().hi()",
        gives: "1"
    ),
    Row(
        isolation,
        "`@globalActor` declarations",
        .works,
        "@globalActor actor G { static let shared = G() }\n@G func f() -> Int { 1 }\nawait f()",
        gives: "1"
    ),
    Row(
        isolation,
        "`isolated` parameters",
        .missing,
        "actor C { var n = 0 }\nfunc f(_ c: isolated C) -> Int { c.n }\nawait f(C())",
        "The access is treated as coming from outside the actor."
    ),
    Row(
        isolation,
        "Calling a `@MainActor` function from outside it",
        .acceptsWhatSwiftRejects,
        "@MainActor func f() -> Int { 1 }\nfunc g() -> Int { f() }\ng()",
        "`@MainActor` is accepted and nothing is isolated."
    ),
    Row(
        isolation,
        "Capturing a non-`Sendable` class in a task",
        .acceptsWhatSwiftRejects,
        "class C { var x = 0 }\nlet c = C()\nTask { c.x += 1 }\n1",
        "`Sendable` is not checked."
    ),
    Row(
        isolation,
        "Mutating a captured `var` in a `@Sendable` closure",
        .acceptsWhatSwiftRejects,
        "var n = 0\nTask { n += 1 }\n1",
        "`@Sendable` captures are not checked."
    ),

    // MARK: Streams, continuations and executors
    Row(
        streams,
        "`AsyncStream`",
        .missing,
        "let s = AsyncStream<Int> { c in c.yield(1); c.finish() }\nvar t = 0\nfor await v in s { t += v }\nt"
    ),
    Row(
        streams,
        "`withCheckedContinuation`",
        .missing,
        "await withCheckedContinuation { c in c.resume(returning: 3) }"
    ),
    Row(
        streams,
        "An `AsyncSequence` a script declares",
        .missing,
        """
        struct S: AsyncSequence {
            typealias Element = Int
            struct I: AsyncIteratorProtocol {
                var n = 0
                mutating func next() async -> Int? { n += 1; return n < 3 ? n : nil }
            }
            func makeAsyncIterator() -> I { I() }
        }
        var t = 0
        for await x in S() { t += x }
        t
        """
    ),
    Row(
        streams,
        "`Mutex` and `Atomic` (the Synchronization module)",
        .missing,
        "import Synchronization\nlet m = Mutex(0)\n1"
    ),
    Row(streams, "Custom executors (`SerialExecutor`, `TaskExecutor`)", .missing),

    // MARK: Language
    Row(
        language,
        "Generic functions",
        .works,
        "func f<T: Equatable>(_ a: T, _ b: T) -> Bool { a == b }\nf(1, 1)",
        gives: "true"
    ),
    Row(
        language,
        "Protocols with associated types",
        .works,
        "protocol P { associatedtype A; func a() -> A }\nstruct S: P { func a() -> Int { 1 } }\nS().a()",
        gives: "1"
    ),
    Row(
        language,
        "`any P` and `some P`",
        .works,
        "protocol P { func f() -> Int }\nstruct S: P { func f() -> Int { 1 } }\nfunc g() -> some P { S() }\nlet x: any P = S()\ng().f() + x.f()",
        gives: "2"
    ),
    Row(
        language,
        "Default implementations in protocol extensions",
        .works,
        "protocol P { func f() -> Int }\nextension P { func f() -> Int { 1 } }\nstruct S: P {}\nS().f()",
        gives: "1"
    ),
    Row(
        language,
        "Enums with payloads and patterns",
        .works,
        "enum E { case a(Int), b }\nfunc f(_ e: E) -> Int {\n switch e { case .a(let n): return n\n case .b: return 0 }\n}\nf(.a(4))",
        gives: "4"
    ),
    Row(
        language,
        "Typed throws",
        .works,
        "enum Err: Error { case x }\nfunc f() throws(Err) { throw .x }\nvar r = 0\ndo { try f() } catch { r = 1 }\nr",
        gives: "1"
    ),
    Row(
        language,
        "Classes with `override` and `super`",
        .works,
        "class A { func f() -> Int { 1 } }\nclass B: A { override func f() -> Int { 2 } }\nB().f()",
        gives: "2"
    ),
    Row(
        language,
        "Extensions with a `where` clause",
        .works,
        "extension Array where Element == Int { func total() -> Int { reduce(0, +) } }\n[1, 2].total()",
        gives: "3"
    ),
    Row(
        language,
        "Subscripts",
        .works,
        "struct S { subscript(i: Int) -> Int { i * 2 } }\nS()[3]",
        gives: "6"
    ),
    Row(
        language,
        "`lazy var`",
        .works,
        "struct S { lazy var x = 5 }\nvar s = S()\ns.x",
        gives: "5"
    ),
    Row(
        language,
        "Property observers",
        .works,
        "struct S { var x = 0 { didSet { y += 1 } }; var y = 0 }\nvar s = S()\ns.x = 1\ns.y",
        gives: "1"
    ),
    Row(
        language,
        "Property wrappers",
        .works,
        "@propertyWrapper struct W { var wrappedValue: Int }\nstruct S { @W var x = 1 }\nS().x",
        gives: "1"
    ),
    Row(
        language,
        "Result builders",
        .works,
        "@resultBuilder struct B { static func buildBlock(_ x: Int...) -> Int { x.reduce(0, +) } }\n@B func f() -> Int { 1\n2 }\nf()",
        gives: "3"
    ),
    Row(
        language,
        "Custom operators",
        .works,
        "infix operator +++\nfunc +++ (a: Int, b: Int) -> Int { a + b }\n1 +++ 2",
        gives: "3"
    ),
    Row(
        language,
        "`#if os(…)` and `canImport`",
        .works,
        "#if os(macOS)\nlet r = 1\n#elseif os(Linux)\nlet r = 1\n#else\nlet r = 2\n#endif\n#if canImport(Foundation)\nlet s = 1\n#else\nlet s = 2\n#endif\nr + s",
        gives: "2"
    ),
    Row(
        language,
        "`if` expressions",
        .works,
        "let x = if true { 1 } else { 2 }\nx",
        gives: "1"
    ),
    Row(
        language,
        "`switch` expressions",
        .missing,
        "let r = switch 1 { case 1: 10\n default: 0 }\nr",
        "`if` expressions work."
    ),
    Row(
        language,
        "Synthesized `Equatable` and `Hashable`",
        .works,
        "struct S: Hashable { var x = 1 }\nSet([S(), S()]).count",
        gives: "1"
    ),
    Row(
        language,
        "Key paths used as functions",
        .works,
        "struct S { var x: Int }\n[S(x: 2), S(x: 1)].map(\\.x)",
        gives: "[2, 1]"
    ),
    Row(
        language,
        "Key path subscripts, `x[keyPath: \\S.v]`",
        .missing,
        "struct S { var x = 1 }\nS()[keyPath: \\S.x]"
    ),
    Row(language, "Regex literals, `/ab/`", .missing, "\"abc\".contains(/b/)"),
    Row(
        language,
        "Noncopyable types and `consume`",
        .missing,
        "struct F: ~Copyable { var x = 1 }\nlet f = F()\nf.x"
    ),
    Row(
        language,
        "Parameter packs, `each T`",
        .missing,
        "func f<each T>(_ x: repeat each T) -> Int { 1 }\nf(1, \"a\")"
    ),
    Row(
        language,
        "Custom string interpolation",
        .missing,
        "struct S: ExpressibleByStringInterpolation { init(stringLiteral v: String) {} }\n1"
    ),
    Row(
        language,
        "`Codable`: `JSONEncoder` and `JSONDecoder`",
        .missing,
        "struct S: Codable { var x = 1 }\ntry JSONEncoder().encode(S()).count"
    ),
    Row(language, "Macros a program declares", .missing),

    // MARK: Host boundary
    Row(host, "Importing a package or module at run time", .missing),
    Row(host, "A script's struct or enum passed where Swift wants a real type", .missing),
    Row(host, "Protocols with associated types as values (`some Collection`)", .missing),
    Row(host, "Swift calling a script type's methods; subclassing a Swift class", .missing),

    // MARK: Execution model
    Row(
        model,
        "Tasks run in parallel",
        .missing,
        nil,
        "Tasks are threads behind one lock and switch only at waits, so CPU-bound tasks run one at a time."
    ),
    Row(
        model,
        "A task spinning on state another task sets",
        .missing,
        nil,
        "It can deadlock, as nothing releases the lock until a wait."
    ),
]

// MARK: The rows run

@Test(arguments: rows.filter { $0.source != nil })
private func aRowDoesWhatTheTableSays(_ row: Row) throws {
    let swiit = Interpreter()
    var value: Value?
    var failure: (any Error)?
    do { value = try swiit.evaluate(row.source!) } catch { failure = error }

    switch row.support {
    case .works:
        #expect(failure == nil, "it should run: \(failure.map { "\($0)" } ?? "")")
        #expect(value.map { "\($0)" } == row.result)
    case .rejectedLikeSwift, .missing:
        #expect(failure != nil, "it runs now, and the table says it does not: \(row.feature)")
    case .acceptsWhatSwiftRejects:
        #expect(failure == nil, "it is rejected now: \(failure.map { "\($0)" } ?? "")")
    }
}

// MARK: The article

private let articleURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/Swiit/Swiit.docc/SwiftSupport.md")

private func renderedArticle() -> String {
    var out = """
        # Swift support

        What Swiit does with Swift code, feature by feature, against the Swift compiler.

        ## Overview

        Each row is a program that runs in the test suite, so the status is what the interpreter does today, and
        a feature that starts to work fails its row until this page is updated. A row without a program states a
        limit the tests cannot show. The page is written from the table in `Tests/SwiitTests/SwiftSupportTests.swift`.

        - **Works**: it runs, with the result the compiler's program gives.
        - **Rejected, as in Swift**: Swiit reports an error where the compiler does.
        - **Not supported**: Swiit reports an error, or has no such API, where Swift accepts it.
        - **Runs; Swift rejects it**: Swiit accepts a program the compiler rejects, so a program that
          compiles is fine here, and the reverse does not hold.

        """
    var areas: [String] = []
    for row in rows where !areas.contains(row.area) { areas.append(row.area) }
    for area in areas {
        out += "\n## \(area)\n\n| Feature | Status | Note |\n| --- | --- | --- |\n"
        for row in rows where row.area == area {
            let note = row.note.replacingOccurrences(of: "|", with: "\\|")
            out += "| \(row.feature) | \(row.support.rawValue) | \(note) |\n"
        }
    }
    return out
}

@Test func theSupportArticleIsCurrent() throws {
    let article = renderedArticle()
    if ProcessInfo.processInfo.environment["SWIIT_WRITE_SUPPORT"] != nil {
        try article.write(to: articleURL, atomically: true, encoding: .utf8)
    }
    let committed = try String(contentsOf: articleURL, encoding: .utf8)
    #expect(
        committed == article,
        "Sources/Swiit/Swiit.docc/SwiftSupport.md is out of date: run SWIIT_WRITE_SUPPORT=1 swift test --filter theSupportArticleIsCurrent"
    )
}
