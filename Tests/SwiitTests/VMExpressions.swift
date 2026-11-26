// The programs of VMTests whose expressions the loop compiles that it once left to the tree evaluator:
// a conditional expression, and the rest of what the tree nodes of the compiled functions were.

let vmExpressions: [VMSample] = [
    VMSample(
        name: "a conditional expression, in a recursion and nested",
        source: """
            func fib(_ n: Int) -> Int { n < 2 ? n : fib(n - 1) + fib(n - 2) }
            func sign(_ n: Int) -> String { n < 0 ? "negative" : n == 0 ? "zero" : "positive" }
            func pick(_ flag: Bool, _ a: Int, _ b: Int) -> Int {
                var total = a
                total = flag ? total + b : total - b
                return total + (flag ? 1 : 0)
            }
            print(fib(12), sign(-3), sign(0), sign(8), pick(true, 5, 2), pick(false, 5, 2))
            """,
        compiles: ["fib", "sign", "pick"],
        trees: 0
    ),
    VMSample(
        name: "an if expression with else if, in a loop, and one that calls",
        source: """
            func f(_ n: Int) -> Int {
                var sum = 0
                for i in 0..<n {
                    let step = if i % 3 == 0 { 3 } else if i % 2 == 0 { 2 } else { 1 }
                    sum += step * (i > 4 ? g(i) : 1)
                }
                return sum
            }
            func g(_ x: Int) -> Int { x > 6 ? x * 2 : x }
            f(10)
            """,
        compiles: ["f", "g"],
        trees: 0
    ),
    VMSample(
        name: "literals of every kind, shown",
        source: """
            func h(_ i: Int) { print([i, i + 1], (a: i, b: 2, i), ["k": i], [[i], [1]]) }
            h(3)
            """,
        compiles: ["h"],
        trees: 0
    ),
    VMSample(
        name: "list, tuple and dictionary literals, nested and with calls in them",
        source: """
            func g(_ x: Int) -> Int { x * 2 }
            func f(_ n: Int) -> Int {
                var total = 0
                for i in 0..<n {
                    let xs = [i, g(i), i + 1]
                    let t = (name: "a", value: g(i), i)
                    let d = ["k": i, "j": g(i)]
                    let nested = [[i], [g(i), 3]]
                    total += xs.count + t.value + t.2 + (d["j"] ?? 0) + nested[1][0]
                    print(xs, t, d["k"] ?? -1, nested)
                }
                var big = Array(0..<50)
                let wrapped = [big, [1]]
                big.append(7)
                return total + wrapped[0].count + big.count
            }
            f(4)
            """,
        compiles: ["f", "g"],
        loops: 0
    ),
    VMSample(
        name: "force unwrap, casts, and a value shown by its static type",
        source: """
            func f(_ n: Int) -> String {
                let maybe: Int? = n > 2 ? n : nil
                var any: Any = n
                if n % 2 == 0 { any = "text" }
                var out = ""
                out += "\\(maybe ?? -1) \\(maybe)"
                out += (any as? String) ?? "none"
                out += any is Int ? " int" : " other"
                out += " \\(maybe!)"
                return out
            }
            print(f(5), f(4))
            """,
        compiles: ["f"],
        trees: 0
    ),
    VMSample(
        name: "a call that returns nothing, tried as a value",
        source: """
            func noisy(_ n: Int) throws { if n > 1 { throw E.bad }; print("ran \\(n)") }
            enum E: Error { case bad }
            func f(_ n: Int) -> Int {
                let a = try? noisy(n)
                return a == nil ? 0 : 1
            }
            print(f(1), f(2))
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "an element of a dictionary, a string and a struct with a subscript, and a default",
        source: """
            struct Grid {
                var cells = [10, 20, 30]
                subscript(i: Int) -> Int { cells[i] * 2 }
            }
            func f(_ words: [String]) -> Int {
                var counts: [String: Int] = [:]
                for w in words { counts[w] = counts[w, default: 0] + 1 }
                let grid = Grid()
                let nested = [[1, 2], [3, 4]]
                let text = "hello"
                var sum = counts["a", default: 100] + counts["zz", default: 7]
                for i in 0..<3 { sum += grid[i] + nested[i % 2][1] }
                return sum + (counts["b"] ?? 0) + text.count
            }
            f(["a", "b", "a", "c", "a"])
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "paths of two steps or more from a local, set and changed in place",
        source: """
            struct Pos { var x = 0; var y = 0.5 }
            struct Body { var pos = Pos(); var trail: [Int] = []; var tags: [String: [Int]] = [:] }
            func f(_ n: Int) -> Int {
                var grid = [[0, 0, 0], [0, 0, 0]]
                var b = Body()
                var maybe: [Int]? = [1, 2, 3]
                for i in 0..<n {
                    grid[i % 2][i % 3] += i
                    grid[1][0] = grid[1][0] + 1
                    b.pos.x += i
                    b.pos.y = 2
                    b.trail += [i]
                    b.tags["k"] = [i]
                    maybe![i % 3] = i * 10
                }
                b.tags["k", default: []][0] = 99
                return grid[0][0] + grid[1][0] + grid[1][2] + b.pos.x + Int(b.pos.y) + b.trail.count
                    + (b.tags["k"]?[0] ?? 0) + maybe![1]
            }
            f(7)
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "a path through an observer or a computed property stays the tree evaluator's",
        source: """
            struct Inner { var v = 1 { didSet { print("v is now \\(v)") } }; var twice: Int { get { v * 2 } set { v = newValue / 2 } } }
            struct Outer { var inner = Inner(); var items = [Inner()] }
            func f() -> Int {
                var o = Outer()
                o.inner.v = 5
                o.inner.twice = 20
                o.items[0].v += 3
                return o.inner.v + o.items[0].twice
            }
            f()
            """,
        compiles: ["f"]
    ),
    VMSample(
        name:
            "methods that look up self by name: a variadic call, closures, an error, and mutation",
        source: """
            func total(_ xs: Int...) -> Int { xs.reduce(0, +) }
            struct Acc {
                var base = 10
                var log: [Int] = []
                func viaVariadic(_ a: Int) -> Int { total(a, base, 3) + self.base }
                func viaClosure(_ n: Int) -> Int { (0..<n).map { $0 + base }.reduce(0, +) }
                func escaping() -> (Int) -> Int { let b = base; return { x in x + b } }
                func fails(_ n: Int) throws -> Int {
                    if n > 1 { throw E.bad(n) }
                    return base + n
                }
                mutating func push(_ x: Int) -> Int { log.append(x + base); base += 1; return log.count }
                mutating func quiet() { }
                func nothing() -> Int { 42 }
            }
            enum E: Error { case bad(Int) }
            func f(_ n: Int) -> Int {
                var a = Acc()
                var sum = a.viaVariadic(n) + a.viaClosure(n) + a.escaping()(n)
                sum += a.push(n) + a.push(n + 1)
                a.quiet()
                do { sum += try a.fails(n) } catch { sum += 1000 }
                sum += a.nothing() + a.base + a.log.count
                return sum + total(1, 2)
            }
            print(f(1), f(3))
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "class methods that look up self by name, called from methods",
        source: """
            func twice(_ xs: Int...) -> Int { xs.reduce(0, +) * 2 }
            class Counter {
                var n = 0
                var step = 2
                func bump() -> Int { n += step; return twice(n, step) }
                func many(_ k: Int) -> Int {
                    var t = 0
                    for _ in 0..<k { t += bump() }
                    let doubled = [1, 2, 3].map { $0 * step }
                    return t + doubled.reduce(0, +) + n
                }
            }
            func f(_ k: Int) -> Int {
                let c = Counter()
                return c.many(k) + c.n
            }
            print(f(2), f(5))
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "an assignment through a place whose value only reads: members, elements, arithmetic",
        source: """
            struct P { var x = 1; var y = 0; var z: Int { x * 3 }; var items = [1, 2, 3] }
            enum Dir { case north, south }
            struct Q { var dir = Dir.north; var count = 0 }
            func f(_ n: Int) -> Int {
                var p = P()
                var grid = [[1, 1, 1], [0, 0, 0]]
                var xs = [5, 6, 7]
                var d = ["a": 1, "b": 2]
                var q = Q()
                for i in 0..<n {
                    p.y = p.x
                    p.x += p.y + i
                    p.y = p.z
                    p.items[0] = p.items[2] + p.x
                    grid[1][i % 3] = grid[0][i % 3] + grid[1][(i + 1) % 3]
                    xs[i % 3] = xs[(i + 1) % 3] * 2
                    d["a"] = d["b"]! + p.y
                    q.count = q.count + xs.count
                    q.dir = .south
                }
                return p.x + p.y + p.items[0] + grid[1][0] + xs[0] + d["a"]! + q.count + (q.dir == .south ? 1 : 0)
            }
            f(5)
            """,
        compiles: ["f"]
    ),
    VMSample(
        name:
            "the common assignments through self and into a global run without the tree evaluator",
        source: """
            class C { var n = 0; var m = 0; func bump() { self.n += 1; m = n } }
            struct S { var x = 0; mutating func inc() { self.x += 1; x = x + 1 } }
            struct T { var x: Int; var y: Int; init(a: Int) { self.x = a; self.y = a + 1 } }
            class D { var x: Int; var y = 2; init(a: Int) { self.x = a } }
            var vec = [0, 0, 0]
            func f() -> Int {
                let c = C()
                var s = S()
                var t = 0
                for i in 0..<5 {
                    c.bump()
                    s.inc()
                    t += T(a: i).y + D(a: i).x
                    vec[i % 3] = i * 2
                    vec[0] += 1
                }
                return c.n + s.x + t + vec[0] + vec[1]
            }
            f()
            """,
        compiles: ["f"],
        treeRuns: 0
    ),
    VMSample(
        name:
            "methods that read self as a value: fields, other methods, enums, extensions, closures",
        source: """
            func total(_ xs: Int...) -> Int { xs.reduce(0, +) }
            struct V {
                var x = 3
                var y = 4
                var tags = [1, 2]
                var sum: Int { x + y }
                func scaled(_ k: Int) -> Int { sum * k }
                func twice() -> Int { scaled(2) + self.scaled(1) }
                func viaVariadic() -> Int { total(x, y, tags.count) }
                func viaClosure() -> Int { tags.map { $0 + x }.reduce(0, +) }
                func made() -> V { var copy = self; copy.x += 10; return copy }
                func bound() -> Int { tags.map(scaled).reduce(0, +) }
            }
            enum Shape {
                case circle(Int), square(Int)
                func area() -> Int {
                    switch self {
                    case .circle(let r): return 3 * r * r
                    case .square(let s): return s * s
                    }
                }
                var doubled: Int { area() * 2 }
            }
            extension Int { func squared() -> Int { self * self }; func plus(_ other: Int) -> Int { self + other } }
            protocol Named { var name: String { get } }
            extension Named { func greeting() -> String { "hi " + name } }
            struct Person: Named { var name: String }
            func f(_ n: Int) -> Int {
                var v = V()
                var sum = 0
                for i in 0..<n {
                    sum += v.twice() + v.viaVariadic() + v.viaClosure() + v.made().x + v.bound()
                    sum += Shape.circle(i).area() + Shape.square(i).doubled + i.squared().plus(i)
                    v.x += 1
                }
                return sum + Person(name: "ann").greeting().count
            }
            print(f(4), f(1))
            """,
        compiles: ["f"]
    ),
    VMSample(
        name:
            "closures that bridged members call: one and two arguments, a function, a key path, an error",
        source: """
            struct P { var x: Int; var name: String }
            func double(_ n: Int) -> Int { n * 2 }
            func pick(_ n: Int) throws -> Int { if n == 3 { throw E.bad }; return n }
            enum E: Error { case bad }
            func f(_ n: Int) -> Int {
                let xs = Array(0..<n)
                let ps = xs.map { P(x: $0, name: "p\\($0)") }
                var total = xs.map { $0 + 1 }.filter { $0 % 2 == 0 }.reduce(0) { $0 + $1 }
                total += xs.map(double).reduce(0, +)
                total += ps.map(\\.x).reduce(0, +)
                total += ps.sorted { $0.x > $1.x }.first?.x ?? 0
                total += xs.compactMap { $0 % 2 == 0 ? $0 : nil }.count
                total += xs.map { a in xs.map { b in a * b }.reduce(0, +) }.reduce(0, +)
                total += xs.contains { $0 == n - 1 } ? 1 : 0
                total += ps.filter { $0.name.hasPrefix("p1") }.count
                do { total += try xs.map(pick).count } catch { total += 1000 }
                return total
            }
            print(f(3), f(5))
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "method calls the loop makes itself: one site, several types, recursion, defaults",
        source: """
            protocol Shape { func area() -> Int }
            struct Sq: Shape { var s: Int; func area() -> Int { s * s } }
            struct Rect: Shape { var w: Int; var h: Int; func area() -> Int { w * h } }
            struct Tri: Shape { var b: Int; var h: Int; func area() -> Int { b * h / 2 } }
            struct Counter {
                var n: Int
                func next(_ k: Int) -> Int { n + k }
                func fact(_ m: Int) -> Int { m <= 1 ? 1 : m * fact(m - 1) }
                func depth(_ m: Int) -> Int { m == 0 ? n : depth(m - 1) + 1 }
                func scaled(by k: Int = 2) -> Int { n * k }
            }
            func f(_ n: Int) -> Int {
                var shapes: [Shape] = []
                for i in 0..<n {
                    if i % 3 == 0 { shapes.append(Sq(s: i)) }
                    else if i % 3 == 1 { shapes.append(Rect(w: i, h: 2)) }
                    else { shapes.append(Tri(b: i, h: 4)) }
                }
                var total = 0
                for shape in shapes { total += shape.area() }
                let c = Counter(n: 5)
                for i in 0..<n { total += c.next(i) + c.scaled() + c.scaled(by: i) }
                return total + c.fact(6) + c.depth(10)
            }
            print(f(9), f(2))
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "a method replaced between calls, and a type declared after its first call",
        source: """
            struct A { var n = 1; func v() -> Int { n } }
            func run(_ a: A) -> Int { var t = 0; for _ in 0..<3 { t += a.v() }; return t }
            let first = run(A())
            extension A { func w() -> Int { n * 10 } }
            struct B { var n = 2; func v() -> Int { n * 100 } }
            print(first, run(A()), A().w())
            """,
        compiles: ["run"]
    ),
    VMSample(
        name:
            "a class's methods through the loop's own calls: overrides, super, self changes, observers",
        source: """
            class Animal {
                var name: String
                var energy = 10 { didSet { if energy < 0 { energy = 0 } } }
                var log: [Int] = []
                init(name: String) { self.name = name }
                func sound() -> String { "..." }
                func tire(_ n: Int) -> Int { energy -= n; log.append(energy); return energy }
                func twice() -> String { sound() + self.sound() }
                func depth(_ m: Int) -> Int { m == 0 ? energy : depth(m - 1) + 1 }
                func later(_ n: Int) -> () -> Int { { [weak self] in (self?.energy ?? -1) + n } }
            }
            class Dog: Animal {
                override func sound() -> String { "woof" }
                override func tire(_ n: Int) -> Int { super.tire(n * 2) }
            }
            class Cat: Animal { override func sound() -> String { "meow" } }
            func f(_ n: Int) -> String {
                let animals: [Animal] = [Animal(name: "a"), Dog(name: "d"), Cat(name: "c")]
                var out = ""
                var total = 0
                for i in 0..<n {
                    for animal in animals {
                        out += animal.sound()
                        total += animal.tire(i % 3) + animal.depth(2) + animal.later(i)()
                    }
                }
                return out + animals.map { $0.twice() }.joined() + "\\(total) \\(animals[1].log.count)"
            }
            print(f(4), f(8))
            """,
        compiles: ["f"]
    ),
]
