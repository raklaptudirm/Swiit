@_spi(Shell) @testable import Swiit
@_spi(Shell) import SwiitSwiftSyntax
import Foundation
import SwishKit
import Testing

// The two front ends over the same Swift: the hand-written parser is the oracle,
// and the SwiftSyntax front end must give the tree it gives.

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
    ("recursion", "func fact(_ n: Int) -> Int { if n <= 1 { return 1 }; return n * fact(n - 1) }\nlet r = fact(5)"),
    ("closures", "let xs = [1, 2, 3]; let d = xs.map { $0 * 2 }; let e = xs.filter { $0 > 1 }.map { $0 + 1 }"),
    ("closure parameters", "let f = { (x: Int, y: Int) -> Int in x + y }; let g = f(1, 2)"),
    ("structs", "struct Point: Equatable { var x: Int; var y: Int; func sum() -> Int { x + y }; static let origin = Point(x: 0, y: 0) }\nlet p = Point(x: 1, y: 2); let s = p.sum()"),
    ("mutating methods", "struct Counter { var n = 0; mutating func bump() { n += 1 } }\nvar c = Counter(); c.bump()"),
    ("computed properties and init", "struct Temp { var celsius: Double; var fahrenheit: Double { celsius * 1.8 + 32 }; init(f: Double) { celsius = (f - 32) / 1.8 } }\nlet t = Temp(f: 212)"),
    ("enums", "enum Level: Int, Comparable { case low = 1, mid, high }\nlet l = Level.mid"),
    ("enums with payloads", "enum Result { case ok(Int); case failed(code: Int, String) }\nlet r = Result.failed(code: 2, \"no\")"),
    ("switch", "let n = 2\nswitch n {\ncase 1: let a = 1\ncase 2, 3: let b = 2\ndefault: let c = 3\n}"),
    ("switch on enums", "enum E { case a(Int); case b }\nlet e = E.a(1)\nswitch e {\ncase .a(let n) where n > 0: let x = n\ncase .a: let y = 0\ncase .b: let z = 1\n}"),
    ("optionals", "let n: Int? = 3; let a = n!; let b = n ?? 0; let s: String? = \"x\"; let c = s?.count"),
    ("casts", "let x: Any = 1; let a = x as? Int; let b = x is String; let c = x as! Int"),
    ("do and catch", "do { let a = 1 / 1 } catch { let m = 1 }\ndo { let a = 1 } catch let e { let m = e }"),
    ("defer", "func f() { defer { let a = 1 }; let b = 2 }"),
    ("key paths", "struct P { var x: Int }\nlet ps = [P(x: 2), P(x: 1)]\nlet s = ps.sorted(by: \\.x)"),
    ("conditional expression", "let n = 3; let s = n > 2 ? \"big\" : \"small\"; let t = if n > 1 { 1 } else { 2 }"),
    ("nested blocks", "func f(_ n: Int) -> Int {\n    var total = 0\n    for i in 0..<n {\n        if i % 2 == 0 {\n            total += i\n        } else {\n            continue\n        }\n    }\n    return total\n}\nlet r = f(10)"),
]


@Test(arguments: programs)
func theSwiftSyntaxFrontEndGivesTheOraclesTree(_ program: (name: String, source: String)) throws {
    let oracle = try Parser.parse(program.source, bound: [:], plugin: nil)
    let lowered: Program
    do {
        lowered = try SwiftSyntaxFrontEnd().parse(program.source, bound: [:], plugin: nil)
    } catch {
        Issue.record("\(program.name): \(error)")
        return
    }
    if lowered != oracle {
        let expected = SwiftPrinter().source(oracle)
        let actual = SwiftPrinter().source(lowered)
        Issue.record("\(program.name): the trees differ\n--- oracle\n\(expected)\n--- swiftsyntax\n\(actual)\n--- raw oracle\n\(String(reflecting: oracle.statements))\n--- raw swiftsyntax\n\(String(reflecting: lowered.statements))")
    }
}

// MARK: Every program the test suites run

/// Programs harvested from the test suites of the shell and the interpreter:
/// what each parsed. Those that are Swift alone (the oracle reads them without a
/// layer's syntax) are the corpus the second front end is held to.
private func harvested() throws -> [String] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("programs.txt")
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\u{1E}", omittingEmptySubsequences: true).map(String.init)
}

@Test func theSwiftSyntaxFrontEndAgreesOnWhatItReadsOfTheHarvestedPrograms() throws {
    let interpreter = Interpreter(host: SwishHost(), limits: Limits())
    let bound = interpreter.globalNames()
    var swiftOnly = 0, agree = 0, unsupported: [String: Int] = [:], wrong: [String] = []
    for source in try harvested() {
        guard let oracle = try? Parser.parse(source, bound: bound, plugin: nil) else { continue }
        swiftOnly += 1
        do {
            let lowered = try SwiftSyntaxFrontEnd().parse(source, bound: bound, plugin: nil)
            if lowered == oracle { agree += 1 } else { wrong.append(source) }
        } catch {
            let reason = "\(error)".replacingOccurrences(of: #" \(line \d+\)"#, with: "", options: .regularExpression)
            unsupported[reason, default: 0] += 1
        }
    }
    print("harvested Swift-only programs: \(swiftOnly); agree \(agree); unsupported \(unsupported.values.reduce(0, +)); wrong \(wrong.count)")
    for (reason, count) in unsupported.sorted(by: { $0.value > $1.value }).prefix(25) { print("  \(count) × \(reason)") }
    // A tree that differs is a bug; what is unsupported is the work to do, and
    // only goes down: `f -5 -3` is arithmetic to the oracle and two statements
    // to Swift, and the other two are a type and a placeholder it doesn't read.
    #expect(wrong.isEmpty, "\(wrong.count) programs differ, the first: \(wrong.first ?? "")")
    #expect(unsupported.values.reduce(0, +) <= 3, "\(unsupported)")
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
]

private func isIncomplete(_ parse: () throws -> Program) -> Bool? {
    do { _ = try parse(); return nil } catch let error as SyntaxError { return error.incomplete } catch { return false }
}

@Test func bothFrontEndsSayWhenInputIsCutShort() {
    for source in incomplete {
        let oracle = isIncomplete { try Parser.parse(source, bound: [:], plugin: nil) }
        let lowered = isIncomplete { try SwiftSyntaxFrontEnd().parse(source, bound: [:], plugin: nil) }
        #expect(oracle == true, "the oracle: \(source)")
        #expect(lowered == true, "swiftsyntax: \(source)")
    }
}

@Test func bothFrontEndsRefuseWhatIsWrong() {
    for source in wrong {
        let oracle = isIncomplete { try Parser.parse(source, bound: [:], plugin: nil) }
        let lowered = isIncomplete { try SwiftSyntaxFrontEnd().parse(source, bound: [:], plugin: nil) }
        #expect(oracle != nil, "the oracle took it: \(source)")
        #expect(lowered != nil, "swiftsyntax took it: \(source)")
    }
}
