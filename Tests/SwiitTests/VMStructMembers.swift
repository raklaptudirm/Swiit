// The programs of VMTests that read and set the fields of a struct held in a local, and call its plain
// methods, the way the loop does, and the cases it leaves to the tree evaluator: a computed property, a
// setter, an observer, a field of another kind, a method that changes its receiver or throws.

let vmStructMembers: [VMSample] = [
    VMSample(
        name: "fields read and set through a local, in a loop",
        source: """
            struct P { var x = 1; var y = 2.5; var name = "p"; var on = false }
            func f(_ n: Int) -> Int {
                var p = P()
                for i in 0..<n {
                    p.x += i
                    p.y *= 1.5
                    p.name = "q\\(i)"
                    p.on = !p.on
                }
                return p.x + p.name.count + (p.on ? 1 : 0)
            }
            f(10)
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "a field set to a value of another kind, a literal into a Double, an optional field",
        source: """
            struct Q { var d: Double = 0; var o: Int? = nil; var s: Any = 1 }
            func f() -> Double {
                var q = Q()
                q.d = 2
                q.o = 5
                q.o = nil
                q.s = "text"
                q.d += 1.5
                return q.d + Double(q.o ?? 3)
            }
            f()
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "fields with observers, a setter and a computed property",
        source: """
            struct R {
                var log = 0
                var a = 1 { didSet { log += a } }
                var b: Int { get { a * 2 } set { a = newValue } }
            }
            func f() -> Int {
                var r = R()
                r.a = 3
                r.a += 4
                r.b = 10
                return r.a * 100 + r.b + r.log
            }
            f()
            """,
        compiles: ["f"]
    ),
    VMSample(
        name:
            "plain methods with arguments, a mutating one, and one on a class",
        source: """
            struct V {
                var x: Int
                func plus(_ n: Int) -> Int { x + n }
                func scaled(by k: Int, offset: Int) -> Int { x * k + offset }
                mutating func bump() { x += 1 }
            }
            class C { var n = 0; func inc(_ by: Int) -> Int { n += by; return n } }
            func f(_ k: Int) -> Int {
                var v = V(x: 3)
                let c = C()
                var t = 0
                for i in 0..<k {
                    t += v.plus(i) + v.scaled(by: 2, offset: i)
                    v.bump()
                    t += c.inc(1)
                }
                return t
            }
            f(6)
            """,
        compiles: ["f"]
    ),
    VMSample(
        name:
            "a Double argument given an integer, and an extension method",
        source: """
            struct W { var base: Double; func add(_ d: Double) -> Double { base + d } }
            extension W { func twice() -> Double { base * 2 } }
            func f() -> Double {
                let w = W(base: 1)
                return w.add(2) + w.twice()
            }
            f()
            """,
        compiles: ["f"]
    ),
]

let vmFailingStructMembers: [VMSample] = [
    VMSample(
        name: "a mutating method that fails half way leaves the struct as it was",
        source: """
            struct S {
                var v = 1
                mutating func risky(_ d: Int) { v += 100; v = 10 / d }
            }
            func f() -> Int {
                var s = S()
                s.risky(5)
                s.risky(0)
                return s.v
            }
            f()
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "a method called with an argument of the wrong type",
        source: """
            struct V { var x: Int; func plus(_ n: Int) -> Int { x + n } }
            func f(_ s: Any) -> Int {
                let v = V(x: 1)
                return v.plus(s as! Int)
            }
            f("no")
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "an overflow in a field set in place",
        source: """
            struct B { var n = 9223372036854775800 }
            func f() -> Int {
                var b = B()
                for _ in 0..<20 { b.n += 1 }
                return b.n
            }
            f()
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "an error inside a plain method, two calls down",
        source: """
            struct D {
                var d: Int
                func inner(_ x: Int) -> Int { x / d }
                func outer(_ x: Int) -> Int { inner(x) }
            }
            func f() -> Int {
                let v = D(d: 0)
                return v.outer(4)
            }
            f()
            """,
        compiles: ["f"]
    ),
]
