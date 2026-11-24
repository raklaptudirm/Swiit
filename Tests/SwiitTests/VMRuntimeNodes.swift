// The programs of VMTests that use what slice 4 of Docs/vm.md compiled: what the tree evaluator
// runs over a frame of the locals it mentions: members, subscripts, constructors, collections,
// interpolation, casts, iteration, and changes made through a path.

let vmRuntimeNodes: [VMSample] = [
    VMSample(
        name: "a struct's members, methods and a mutating one",
        source: """
            struct P {
                var x: Int
                var y: Int
                func sum() -> Int { x + y }
                mutating func inc() { x += 1 }
            }
            func f() -> Int {
                var p = P(x: 1, y: 2)
                p.inc()
                p.x = p.x * 10
                p.y += 5
                return p.sum() + p.x
            }
            f()
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "an array built and changed in place",
        source: """
            func f(_ n: Int) -> Int {
                var xs: [Int] = []
                for i in 0..<n { xs.append(i * 2) }
                xs[0] = 100
                xs[1] += 5
                var t = 0
                for x in xs { t += x }
                return t + xs.count
            }
            f(6)
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "a dictionary counted, and read by entries",
        source: """
            func f() -> Int {
                var d: [String: Int] = [:]
                for w in ["a", "b", "a", "c", "a"] { d[w, default: 0] += 1 }
                var t = 0
                for (k, v) in d { t += v * k.count }
                return t + (d["a"] ?? 0)
            }
            f()
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "strings: interpolation, characters and joining",
        source: """
            func f(_ n: Int) -> String {
                var s = ""
                for ch in "xyz" { s += "\\(ch)\\(n)," }
                return s + "end \\(n * 2)"
            }
            f(7)
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "an enum made with a payload and switched on",
        source: """
            enum Shape { case circle(Int), rect(Int, Int) }
            func area(_ s: Shape) -> Int {
                switch s {
                case .circle(let r): return 3 * r * r
                case .rect(let w, let h): return w * h
                }
            }
            func f(_ n: Int) -> Int {
                let shapes = [Shape.circle(n), .rect(n, 2), .circle(1)]
                var t = 0
                for s in shapes { t += area(s) }
                return t
            }
            f(3)
            """,
        compiles: ["area", "f"]
    ),
    VMSample(
        name: "a class instance changed through its reference",
        source: """
            class Counter {
                var n = 0
                func bump() { n += 1 }
            }
            func f() -> Int {
                let c = Counter()
                c.bump(); c.bump()
                c.n += 10
                let d = c
                d.bump()
                return c.n
            }
            f()
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "casts, is, optional chaining and force unwrap",
        source: """
            func a(_ v: Any) -> Int {
                if let n = v as? Int { return n }
                if v is String { return -1 }
                return 0
            }
            func b(_ s: String?) -> Int { return s?.count ?? -1 }
            func c(_ s: String?) -> Int { return s!.count }
            a(5) + a("x") + a(2.5) + b("abc") + b(nil) + c("hello")
            """,
        compiles: ["a", "b", "c"]
    ),
    VMSample(
        name: "collection and tuple literals of locals, and a tuple pattern",
        source: """
            func f(_ a: Int, _ b: Int) -> Int {
                let ys = [a, b, a + b]
                let t = (a, b)
                let d = ["k": a, "m": b]
                var s = 0
                for (i, x) in [(1, 2), (3, 4)] { s += i * x }
                return ys.count + t.0 + t.1 + (d["k"] ?? 0) + s
            }
            f(5, 6)
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "a variable a closure shares changed through a path",
        source: """
            struct Box { var v = 1 }
            func f() -> Int {
                var b = Box()
                let bump = { b.v += 10 }
                bump()
                b.v += 1
                bump()
                return b.v
            }
            f()
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "an inout argument that is a member and an element",
        source: """
            struct P { var x = 1 }
            func inc(_ n: inout Int) { n += 1 }
            func f() -> Int {
                var p = P()
                var xs = [10, 20]
                inc(&p.x)
                inc(&xs[1])
                inc(&xs[1])
                return p.x * 100 + xs[1]
            }
            f()
            """,
        compiles: ["inc", "f"]
    ),
    VMSample(
        name: "arrays of arrays and nested subscripts",
        source: """
            func f(_ n: Int) -> Int {
                var grid: [[Int]] = []
                for i in 0..<n {
                    var row: [Int] = []
                    for j in 0..<n { row.append(i * n + j) }
                    grid.append(row)
                }
                grid[1][1] = 100
                var t = 0
                for row in grid { for v in row { t += v } }
                return t
            }
            f(3)
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "key paths, map and filter with a closure that captures",
        source: """
            struct P { var x: Int }
            func f(_ k: Int) -> Int {
                let ps = [P(x: 1), P(x: 2), P(x: 3)]
                let xs = ps.map(\\.x)
                let big = xs.filter { $0 > k }
                return xs.count * 10 + big.count
            }
            f(1)
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "a weak reference read and assigned",
        source: """
            class Thing { var v = 3 }
            func f() -> Int {
                let t = Thing()
                weak var w: Thing? = t
                var r = 0
                if let x = w { r += x.v }
                w = nil
                if w == nil { r += 100 }
                return r
            }
            f()
            """,
        compiles: ["f"]
    ),
]

let vmFailingRuntimeNodes: [VMSample] = [
    VMSample(
        name: "an index out of range in a loop",
        source: """
            func f(_ n: Int) -> Int {
                var xs = [1, 2, 3]
                var t = 0
                for i in 0..<n { t += xs[i] }
                return t
            }
            f(5)
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "a force unwrap of nil two calls down",
        source: """
            func a(_ s: String?) -> Int { return s!.count }
            func b(_ s: String?) -> Int { return a(s) + 1 }
            b(nil)
            """,
        compiles: ["a", "b"]
    ),
    VMSample(
        name: "an error in an interpolation",
        source: """
            func f(_ d: Int) -> String { return "value \\(10 / d)" }
            func g(_ d: Int) -> String { return f(d) }
            g(0)
            """,
        compiles: ["f", "g"]
    ),
    VMSample(
        name: "a member a struct does not have",
        source: """
            struct P { var x = 1 }
            func f() -> Int { let p = P(); return p.nothing }
            f()
            """,
        compiles: []
    ),
]
