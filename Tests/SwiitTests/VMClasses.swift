// The programs of VMTests that read and set the fields of a class's instance and call its methods the
// way the loop does, and where it leaves them to the tree evaluator: an override, `super`, an observer,
// a setter, a computed property, a `let` property, a weak field, a field of another kind.

let vmClasses: [VMSample] = [
    VMSample(
        name: "fields and methods of a class, set from the method and from outside",
        source: """
            class Counter {
                var n = 0
                var step = 1
                var label = "c"
                var scale = 1.5
                func bump(_ by: Int) -> Int { n += by * step; return n }
                func rename(_ s: String) { label = s + "!" }
                func grow() { scale *= 2 }
            }
            func f(_ k: Int) -> Int {
                let c = Counter()
                var t = 0
                for i in 0..<k {
                    t += c.bump(i % 3)
                    c.step = i % 2 + 1
                    c.rename("n\\(i)")
                    c.grow()
                }
                return t + c.n + c.label.count + Int(c.scale)
            }
            f(8)
            """,
        compiles: ["f"]
    ),
    VMSample(
        name:
            "an override, a call to super, and a method on a subclass instance held as its superclass",
        source: """
            class Shape {
                var sides = 0
                func describe() -> Int { sides * 10 }
                func scaled(_ k: Int) -> Int { describe() * k }
            }
            class Square: Shape {
                override func describe() -> Int { super.describe() + 1 }
                func extra() -> Int { sides + 100 }
            }
            func f() -> Int {
                let a = Square()
                a.sides = 4
                let b: Shape = a
                return a.describe() + b.describe() + a.extra() + b.scaled(2)
            }
            f()
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "a class's field with an observer, a setter, a let property and a weak reference",
        source: """
            class Box {
                var log = 0
                var v = 0 { didSet { log += v } }
                var w: Int { get { v * 2 } set { v = newValue } }
                let id = 7
                weak var friend: Box?
                func put(_ n: Int) { v = n; v += 1; w = 5 }
            }
            func f() -> Int {
                let a = Box()
                let b = Box()
                a.friend = b
                a.put(3)
                a.v = 10
                a.w = 20
                return a.v * 1000 + a.log + a.id + (a.friend?.id ?? 0)
            }
            f()
            """,
        compiles: ["f"]
    ),
    VMSample(
        name:
            "initializers of structs and classes: sets, a conversion, a let, an observer, delegation",
        source: """
            struct P {
                let id: Int
                var x: Double
                var y = 5
                var seen = 0 { didSet { seen += 100 } }
                init(id: Int, x: Int) { self.id = id; self.x = Double(x); seen = 1; self.y += 1 }
                init(both: Int) { self.init(id: both, x: both) }
            }
            class Base {
                var a: Int
                var tag = "b"
                init(a: Int) { self.a = a; self.tag = "base\\(a)" }
            }
            class Derived: Base {
                var b: Double
                init(a: Int, b: Int) { self.b = Double(b); super.init(a: a); self.a += 1 }
                convenience init(both: Int) { self.init(a: both, b: both * 2) }
            }
            func f(_ n: Int) -> Int {
                var t = 0
                for i in 0..<n {
                    let p = P(id: i, x: i * 2)
                    let q = P(both: i)
                    let d = Derived(a: i, b: 3)
                    let e = Derived(both: i)
                    t += p.id + Int(p.x) + p.y + p.seen + q.id + d.a + Int(d.b) + e.a + d.tag.count
                }
                return t
            }
            f(5)
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "a failable initializer and one that leaves a field to its default",
        source: """
            struct F {
                var v: Int
                var w = 2
                init?(_ n: Int) { if n < 0 { return nil }; self.v = n }
            }
            func f() -> Int {
                var t = 0
                for i in -2..<3 { if let x = F(i) { t += x.v + x.w } else { t += 100 } }
                return t
            }
            f()
            """,
        compiles: ["f"]
    ),
    VMSample(
        name:
            "structs made by the memberwise initializer: a conversion, a default left out, a nested struct",
        source: """
            struct In { var a: Int; var b: Int = 2 }
            struct Out { var d: Double; var inner: In; var s: String = "s" }
            struct Pair { var x: Int; var y: Int }
            func f(_ n: Int) -> Int {
                var t = 0
                for i in 0..<n {
                    let o = Out(d: 1, inner: In(a: i))
                    let p = Pair(x: i, y: o.inner.b)
                    let q = Pair(x: p.y, y: p.x)
                    t += Int(o.d) + o.inner.a + o.inner.b + p.x + q.x + o.s.count
                }
                return t
            }
            f(6)
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "an initializer that throws, one that delegates, and an extension's",
        source: """
            struct E: Error {}
            struct T {
                var v: Int
                init(_ n: Int) throws { if n < 0 { throw E() }; self.v = n }
                init(twice n: Int) throws { try self.init(n * 2) }
            }
            struct U { var a: Int }
            extension U { init(plus n: Int) { self.init(a: n + 1) } }
            func f() -> Int {
                var t = 0
                for i in -1..<3 {
                    do { t += try T(i).v + (try T(twice: i)).v } catch { t += 50 }
                    t += U(a: i).a + U(plus: i).a
                }
                return t
            }
            f()
            """,
        compiles: ["f"]
    ),
    VMSample(
        name:
            "classes made with defaults only, an inherited initializer, a deinit and a lazy property",
        source: """
            var log: [String] = []
            class Plain { var n = 1; var tags: [String] = [] }
            class Named {
                var name: String
                lazy var shout: String = name + "!"
                init(_ name: String) { self.name = name }
                deinit { log.append("bye \\(name)") }
            }
            class Sub: Named { var extra = 7 }
            func f(_ k: Int) -> Int {
                var t = 0
                for i in 0..<k {
                    let a = Plain()
                    let b = Named("n\\(i)")
                    let c = Sub("s\\(i)")
                    t += a.n + b.name.count + c.extra + b.shout.count
                }
                return t
            }
            let r = f(4)
            print(log.count)
            r
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "an instance changed through another reference, and a class held in a struct",
        source: """
            class Cell { var n = 0; func inc() { n += 1 } }
            struct Holder { var cell: Cell; var k = 1 }
            func f() -> Int {
                let c = Cell()
                let d = c
                var h = Holder(cell: c)
                for _ in 0..<5 { c.inc(); d.inc(); h.cell.inc() }
                h.k += c.n
                return h.k * 100 + d.n
            }
            f()
            """,
        compiles: ["f"]
    ),
]

let vmFailingClasses: [VMSample] = [
    VMSample(
        name:
            "a class's initializer that leaves a property unset, and a call to a class with no initializer",
        source: """
            class Half {
                var a: Int
                var b: Int
                init(a: Int) { self.a = a }
            }
            func f() -> Int { Half(a: 1).a }
            f()
            """,
        compiles: ["f"]
    ),
    VMSample(
        name:
            "an initializer that leaves a field unset, and one that sets a field of the wrong type",
        source: """
            struct H {
                var a: Int
                var b: Int
                init(a: Int) { self.a = a }
            }
            func f() -> Int { H(a: 1).a }
            f()
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "an initializer that sets an Int field to a string",
        source: """
            struct G {
                var a: Int
                init(_ s: Any) { self.a = s as! Int }
            }
            func f() -> Int { G("x").a }
            f()
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "a class's method that fails, two calls down",
        source: """
            class D {
                var d = 0
                func inner(_ x: Int) -> Int { x / d }
                func outer(_ x: Int) -> Int { inner(x) + 1 }
            }
            func f() -> Int {
                let o = D()
                return o.outer(4)
            }
            f()
            """,
        compiles: ["f"]
    ),
]

/// Programs whose calls are all the loop's own: a global function, a method of a struct and of a class, a
/// mutating one, one that calls another, and a method with an owner that calls `super`.
let vmEntered: [VMSample] = [
    VMSample(
        name: "global functions and methods called in a loop",
        source: """
            func sq(_ n: Int) -> Int { n * n }
            struct V {
                var x = 1
                func plus(_ n: Int) -> Int { x + n }
                mutating func bump() { x += 1 }
            }
            class A { var n = 0; func inc(_ by: Int) -> Int { n += by; return n } }
            class B: A { override func inc(_ by: Int) -> Int { super.inc(by * 2) } }
            func f() -> Int {
                var v = V()
                let a = A()
                let b = B()
                var t = 0
                for i in 0..<5 {
                    t += sq(i) + v.plus(i) + a.inc(1) + b.inc(1)
                    v.bump()
                }
                return t + v.x
            }
            f()
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "calls that leave out parameters that have defaults, and a method that does",
        source: """
            var base = 10
            func f(_ a: Int, b: Int = 2, c: Double = 0, d: String = "d", e: Int = base) -> Double {
                Double(a + b + e) + c + Double(d.count)
            }
            struct M { var k = 1; func g(_ x: Int, scale: Int = 3) -> Int { (x + k) * scale } }
            func run() -> Double {
                var t = 0.0
                let m = M()
                for i in 0..<4 {
                    base += i
                    t += f(i) + f(i, b: 5) + f(i, c: 1.5) + f(i, d: "xyz") + f(i, b: 1, e: 2)
                    let g1 = m.g(i)
                    let g2 = m.g(i, scale: 2)
                    t += Double(g1 + g2)
                }
                return t
            }
            run()
            """,
        compiles: ["f", "run"]
    ),
    VMSample(
        name:
            "constructors with initializer bodies, and overloaded functions the checker chose between",
        source: """
            struct P {
                var x: Int
                var y = 5
                init(x: Int) { self.x = x * 2 }
                init(a: Int, b: Int) { self.x = a; self.y = b }
            }
            class K {
                var n: Int
                var tag = "k"
                init(n: Int) { self.n = n + 1 }
            }
            func show(_ n: Int) -> Int { n + 1 }
            func show(_ s: String) -> Int { s.count }
            func show(_ d: Double) -> Int { Int(d) * 3 }
            func f() -> Int {
                var t = 0
                for i in 0..<4 {
                    let p = P(x: i)
                    let q = P(a: i, b: 2)
                    let k = K(n: i)
                    t += p.x + p.y + q.y + k.n + k.tag.count + show(i) + show("ab") + show(1.5)
                }
                return t
            }
            f()
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "computed properties read in a loop: a struct's, a class's, one that reads another",
        source: """
            struct R {
                var w: Int
                var h: Int
                var area: Int { w * h }
                var doubled: Int { area * 2 }
                var label: String { "\\(w)x\\(h)" }
            }
            class C {
                var n = 3
                var next: Int { n + 1 }
                var both: Int { next + n }
            }
            func f() -> Int {
                var r = R(w: 2, h: 3)
                let c = C()
                var t = 0
                for i in 0..<4 {
                    r.w += i
                    c.n += 1
                    t += r.area + r.doubled + r.label.count + c.next + c.both
                }
                return t
            }
            f()
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "closures that name self, made in a method and called by the loop",
        source: """
            struct S {
                var k = 4
                func adder() -> (Int) -> Int { { x in x + self.k } }
                func run(_ n: Int) -> Int {
                    let add = adder()
                    var t = 0
                    for i in 0..<n { t += add(i) + self.k }
                    return t
                }
            }
            func f() -> Int {
                let s = S()
                let g = s.adder()
                var t = s.run(4)
                for i in 0..<3 { t += g(i) }
                return t
            }
            f()
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "calls among the arguments of conversions and of members of Swift types",
        source: """
            struct M { var k = 1; func g(_ x: Int) -> Int { (x + k) * 2 } }
            func sq(_ n: Int) -> Int { n * n }
            func f() -> Double {
                let m = M()
                var t = 0.0
                var s = ""
                for i in 0..<4 {
                    t += Double(m.g(i)) + Double(sq(i))
                    s += String(sq(i)) + "-"
                    t += Double(max(sq(i), m.g(i)))
                }
                return t + Double(s.count) + Double("12".count + sq(2))
            }
            f()
            """,
        compiles: ["f"]
    ),
]
