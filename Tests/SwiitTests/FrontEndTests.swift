@_spi(Layer) @testable import Swiit
import Foundation
import SwiitKit
import Testing

// The front end over Swift alone. What the hand-written parser read, which it
// was held to while it existed, is kept as goldens (below).

private let programs: [(name: String, source: String)] = [
    ("literals", #"let a = 1; let b = 2.5; let c = "hi \n \"there\""; let d = true; var e: Int? = nil"#),
    ("annotations", "let xs: [Int] = [1, 2, 3]; let d: [String: Int] = [\"a\": 1]; var o: Int? = nil"),
    ("operators", "let x = 1 + 2 * 3 - 4 / 2 % 3; let y = x > 3 && x < 10 || x == 0; let z = !y; let w = -x"),
    ("ranges and coalescing", "let r = 1...3; let s = 0..<5; let n: Int? = nil; let v = n ?? 7"),
    ("interpolation", #"let name = "Rak"; let greeting = "hello, \(name)! \(1 + 2)""#),
    ("collections", "let xs = [3, 1, 2]; let ys = xs.sorted(); let first = ys[0]; let d = [\"a\": 1, \"b\": 2]; let a = d[\"a\"]; let e: [String: Int] = [:]"),
    ("tuples", "let t = (a: 1, b: \"x\"); let u = t.a; let v = (1, 2)"),
    ("assignment", "var n = 1; n += 2; n *= 3; var xs = [1, 2]; xs[0] = 9; var t = (a: 1, b: 2); t.a = 5"),
    ("if and else if", "let n = 3\nif n > 5 { let big = 1 } else if n > 1 { let mid = 2 } else { let small = 3 }"),
    ("if let", "let n: Int? = 2\nif let m = n { let k = m + 1 }"),
    ("guard", "func f(_ n: Int?) -> Int { guard let m = n else { return 0 }; return m }"),
    ("while and for", "var i = 0\nwhile i < 3 { i += 1 }\nfor j in 1...3 { let k = j * 2 }\nfor c in \"ab\" { let u = c }"),
    ("break and continue", "for i in 0..<5 { if i == 1 { continue }; if i == 3 { break } }"),
    ("functions", "func add(_ a: Int, _ b: Int) -> Int { a + b }\nfunc greet(name: String, times: Int = 1) -> String { name }\nlet s = add(1, 2); let g = greet(name: \"x\")"),
    ("throwing functions", "func risky(_ n: Int) throws -> Int { n }\nlet a = try? risky(1)\nlet b = try! risky(2)"),
    ("async functions", "func fetch(_ g: () async -> Int) async throws -> Int { await g() }\nfunc one() async -> Int { 1 }\nlet n = try await fetch(one)"),
    ("async let", "func f() async -> Int { 1 }\nfunc g() async -> Int { async let a = f(); async let b: Int = f(); return await a + b }"),
    ("for try await", "func f(_ xs: Flow<Int>) async throws { for try await x in xs { let y = x } }"),
    ("await covers what follows", "func f() async -> Int { 1 }\nlet n = await f() + f() * 2"),
    ("discards", "func f() -> Int { 1 }\n_ = f()\nlet _ = f()"),
    ("recursion", "func fact(_ n: Int) -> Int { if n <= 1 { return 1 }; return n * fact(n - 1) }\nlet r = fact(5)"),
    ("closures", "let xs = [1, 2, 3]; let d = xs.map { $0 * 2 }; let e = xs.filter { $0 > 1 }.map { $0 + 1 }"),
    // An inner closure's `$0` is its own: the outer one takes nothing.
    ("nested anonymous closures", "let xs = [1, 2]; let f = { xs.map { $0 * 2 } }; let g = { $1 + [$0].map { $0 }.count }"),
    ("closure parameters", "let f = { (x: Int, y: Int) -> Int in x + y }; let g = f(1, 2)"),
    ("structs", "struct Point: Equatable { var x: Int; var y: Int; func sum() -> Int { x + y }; static let origin = Point(x: 0, y: 0) }\nlet p = Point(x: 1, y: 2); let s = p.sum()"),
    ("mutating methods", "struct Counter { var n = 0; mutating func bump() { n += 1 } }\nvar c = Counter(); c.bump()"),
    ("computed properties and init", "struct Temp { var celsius: Double; var fahrenheit: Double { celsius * 1.8 + 32 }; init(f: Double) { celsius = (f - 32) / 1.8 } }\nlet t = Temp(f: 212)"),
    ("enums", "enum Level: Int, Comparable { case low = 1, mid, high }\nlet l = Level.mid"),
    ("enums with payloads", "enum Result { case ok(Int); case failed(code: Int, String) }\nlet r = Result.failed(code: 2, \"no\")"),
    ("switch", "let n = 2\nswitch n {\ncase 1: let a = 1\ncase 2, 3: let b = 2\ndefault: let c = 3\n}"),
    ("a guard on a case's last pattern", "let n = 2\nswitch n {\ncase 1, 2 where n > 1: let a = 1\ndefault: let b = 2\n}"),
    ("switch on enums", "enum E { case a(Int); case b }\nlet e = E.a(1)\nswitch e {\ncase .a(let n) where n > 0: let x = n\ncase .a: let y = 0\ncase .b: let z = 1\n}"),
    ("optionals", "let n: Int? = 3; let a = n!; let b = n ?? 0; let s: String? = \"x\"; let c = s?.count"),
    ("casts", "let x: Any = 1; let a = x as? Int; let b = x is String; let c = x as! Int"),
    ("do and catch", "do { let a = 1 / 1 } catch { let m = 1 }\ndo { let a = 1 } catch let e { let m = e }"),
    ("defer", "func f() { defer { let a = 1 }; let b = 2 }"),
    ("throw and catch clauses", "struct Oops: Error { let code: Int }\nenum Bad: Error { case input, network(code: Int) }\nfunc f() throws { throw Oops(code: 1) }\ndo { try f() } catch let e as Oops where e.code > 0 { let a = e.code } catch is Oops { let b = 1 } catch Bad.network(let code) { let c = code } catch { let d = error }"),
    ("cast patterns in a switch", "let x: Any = 1\nswitch x {\ncase let n as Int: let a = n\ncase _ as String: let b = 1\ncase is Double: let c = 2\ndefault: let d = 3\n}"),
    ("key paths", "struct P { var x: Int }\nlet ps = [P(x: 2), P(x: 1)]\nlet s = ps.sorted(by: \\.x)"),
    ("conditional expression", "let n = 3; let s = n > 2 ? \"big\" : \"small\"; let t = if n > 1 { 1 } else { 2 }"),
    ("nested blocks", "func f(_ n: Int) -> Int {\n    var total = 0\n    for i in 0..<n {\n        if i % 2 == 0 {\n            total += i\n        } else {\n            continue\n        }\n    }\n    return total\n}\nlet r = f(10)"),
]


// MARK: Every program the test suites run

/// Programs harvested from the test suites of the shell and the interpreter:
/// what each parsed. Those that are Swift alone (the oracle reads them without a
/// layer's syntax) are the corpus the second front end is held to.
private func harvested() throws -> [String] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("programs.txt")
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\u{1E}", omittingEmptySubsequences: true).map(String.init)
}

// MARK: Input that isn't a program

/// Input cut short, which a prompt answers with another line.
private let incomplete = [
    "let xs = [1, 2,", "func f() {", "if true {", "let s = \"abc", "for i in 1...3 {", "while true {\n    let a = 1",
    "struct P {", "enum E {\n    case a", "let t = (1,", "do {", "switch 1 {", "let f = { (x: Int) in",
]

/// Input that is wrong where it is, and more lines wouldn't help.
private let wrong = [
    "let = 1", "func (", "let x: = 3", "1 +* 2", "if { }", "for in x { }", "let 1x = 3", "}", ")", "let a = ]",
    // A case holds one guard, its last pattern's.
    "switch 1 {\ncase 1 where false, 2: let a = 1\ndefault: let b = 2\n}",
    // Comparisons that end in `=` aren't compound assignments.
    "var a = 1; a === 1", "var a = 1; a !== 1",
]

private func isIncomplete(_ parse: () throws -> Program) -> Bool? {
    do { _ = try parse(); return nil } catch let error as SyntaxError { return error.incomplete } catch { return false }
}

@Test func inputCutShortAsksForMore() {
    for source in incomplete {
        #expect(isIncomplete { try SwiftSyntaxFrontEnd().parse(source, bound: [:], plugin: nil) } == true, Comment(rawValue: source))
    }
}

@Test func whatIsWrongIsRefused() {
    for source in wrong {
        #expect(isIncomplete { try SwiftSyntaxFrontEnd().parse(source, bound: [:], plugin: nil) } == false, Comment(rawValue: source))
    }
}

// MARK: What the hand-written parser read, kept

/// What the front end reads is held to what the hand-written parser read
/// (Goldens/swift.txt, made from it before it was deleted): each of this
/// file's programs and the harvested Swift-only ones, as the tree printed
/// back as Swift. A change is a decision, not an accident.
private func goldenURL() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Goldens/swift.txt")
}

/// The records of the golden file: a program's name and its printed tree.
private func goldenRecords() throws -> [(name: String, tree: String)] {
    try String(contentsOf: goldenURL(), encoding: .utf8).split(separator: "\u{1E}", omittingEmptySubsequences: true).map { record in
        let parts = record.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
        return (String(parts[0]), String(parts[1]))
    }
}

/// Every program the golden file has, by name: this file's, then the harvested ones as `#index`.
private func goldenPrograms() throws -> [(name: String, source: String)] {
    programs.map { ($0.name, $0.source) } + (try harvested()).enumerated().map { ("#\($0.offset)", $0.element) }
}

@Test func theFrontEndReadsAsTheHandWrittenParserDid() throws {
    let interpreter = Interpreter(host: SwiitHost(), limits: Limits())
    let bound = interpreter.globalNames()
    // `UPDATE_GOLDENS=1` writes the file again from the front end as it is.
    if ProcessInfo.processInfo.environment["UPDATE_GOLDENS"] != nil {
        var records: [String] = []
        for (name, source) in try goldenPrograms() {
            guard let lowered = try? SwiftSyntaxFrontEnd().parse(source, bound: name.hasPrefix("#") ? bound : [:], plugin: nil) else { continue }
            records.append("\(name)\u{1F}\(SwiftPrinter().source(lowered))")
        }
        try records.joined(separator: "\u{1E}").write(to: goldenURL(), atomically: true, encoding: .utf8)
    }
    let golden = try goldenRecords()
    let sources = Dictionary(uniqueKeysWithValues: try goldenPrograms().map { ($0.name, $0.source) })
    #expect(golden.count > 250)
    var wrong: [String] = []
    for (name, tree) in golden {
        let source = try #require(sources[name])
        guard let lowered = try? SwiftSyntaxFrontEnd().parse(source, bound: name.hasPrefix("#") ? bound : [:], plugin: nil) else {
            wrong.append("\(name): not read\n\(source.prefix(100))")
            continue
        }
        if SwiftPrinter().source(lowered) != tree { wrong.append("\(name):\n\(source.prefix(100))") }
    }
    #expect(wrong.isEmpty, "\(wrong.count) programs differ from what the hand-written parser read:\n\(wrong.prefix(5).joined(separator: "\n---\n"))")
}
