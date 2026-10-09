@_spi(Shell) @testable import Swiit
import SwishKit
import Testing

// The printer's own check: what it prints reads back as the same tree. The
// programs are Swift, so what comes out is also what `swiftc` would accept.

private func tree(_ source: String) throws -> Program {
    try Parser.parse(source, bound: [:], plugin: nil)
}

private func printed(_ source: String) throws -> String {
    SwiftPrinter().source(try tree(source))
}

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
func whatTheSwiftPrinterPrintsReadsBackAsTheSameTree(_ program: (name: String, source: String)) throws {
    let original = try tree(program.source)
    let text = SwiftPrinter().source(original)
    let again: Program
    do { again = try tree(text) } catch {
        Issue.record("\(program.name): printed\n\(text)\nwhich doesn't parse: \(error)")
        return
    }
    #expect(again == original, "\(program.name): printed\n\(text)")
}

@Test func theSwiftPrinterShowsWhatItPrints() throws {
    #expect(try printed("let a = 1 + 2 * 3") == "let a = 1 + (2 * 3)")
    #expect(try printed("var xs = [1, 2]; xs[0] += 5") == "var xs = [1, 2]\nxs[0] += 5")
    #expect(try printed("func f(_ n: Int) -> Int { n * 2 }") == "func f(_ n: Int) -> Int {\n    n * 2\n}")
    #expect(try printed("if true { let a = 1 } else { let b = 2 }") == "if true {\n    let a = 1\n} else {\n    let b = 2\n}")
}
