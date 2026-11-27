// The programs of VMTests that use what slice 5 of Docs/vm.md compiled: the kinds of function that are
// not a plain function of the global scopes. Methods and initializers, which have `self`, and generic
// functions, which have their type parameters.

let vmKinds: [VMSample] = [
    VMSample(
        name: "a struct's methods, a mutating one and a computed property",
        source: """
            struct Counter {
                var n = 0
                var twice: Int { n * 2 }
                func peek() -> Int { n }
                mutating func bump(by step: Int) { n += step }
                mutating func reset() { n = 0 }
            }
            func f() -> Int {
                var c = Counter()
                c.bump(by: 3)
                c.bump(by: 4)
                let seen = c.peek() + c.twice
                c.reset()
                return seen + c.n
            }
            var c = Counter()
            c.bump(by: 5)
            c.bump(by: 6)
            print(c.n, c.peek(), c.twice)
            f()
            """,
        compiles: ["f"],
        entirely: true
    ),
    VMSample(
        name: "a throwing initializer, caught and not",
        source: """
            struct Natural {
                var n: Int
                struct Negative: Error {}
                init(_ n: Int) throws {
                    if n < 0 { throw Negative() }
                    self.n = n
                }
            }
            func f(_ x: Int) -> Int {
                var t = 0
                for i in 0..<x {
                    do {
                        t += try Natural(i - 2).n
                    } catch {
                        t += 100
                    }
                }
                return t + ((try? Natural(-1))?.n ?? 7)
            }
            f(4)
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "initializers of a struct, one that calls another and one that may fail",
        source: """
            struct Box {
                var a: Int
                var b: Int
                init(a: Int, b: Int) { self.a = a; self.b = b * 2 }
                init(both: Int) { self.init(a: both, b: both) }
                init?(positive: Int) {
                    if positive <= 0 { return nil }
                    self.a = positive
                    self.b = positive
                }
            }
            func f(_ n: Int) -> Int {
                let x = Box(a: 1, b: n)
                let y = Box(both: n)
                var t = x.a + x.b + y.a + y.b
                if let z = Box(positive: n) { t += z.a } else { t -= 1000 }
                if let w = Box(positive: -n) { t += w.b } else { t -= 1 }
                return t
            }
            f(5)
            """,
        compiles: ["f"],
        entirely: true
    ),
    VMSample(
        name: "a class, its inheritance, super and an override",
        source: """
            class Animal {
                var name: String
                var legs: Int
                init(name: String, legs: Int) { self.name = name; self.legs = legs }
                func describe() -> String { "\\(name) has \\(legs) legs" }
                func sound() -> String { "..." }
            }
            class Dog: Animal {
                var tricks = 0
                init(name: String) {
                    super.init(name: name, legs: 4)
                    tricks = 2
                }
                override func sound() -> String { "woof" }
                override func describe() -> String { super.describe() + " and \\(tricks) tricks" }
                func learn() { tricks += 1 }
            }
            func f() -> String {
                let d = Dog(name: "Rex")
                d.learn()
                return d.describe() + " " + d.sound()
            }
            f()
            """,
        compiles: ["f"],
        entirely: true
    ),
    VMSample(
        name: "class state shared through a reference, and a static method",
        source: """
            class Tally {
                var total = 0
                static var made = 0
                static func make() -> Tally { made += 1; return Tally() }
                func add(_ x: Int) -> Tally { total += x; return self }
            }
            func f() -> Int {
                let t = Tally.make()
                let u = t
                _ = t.add(3).add(4)
                u.total += 1
                return t.total * 10 + Tally.made
            }
            f()
            """,
        compiles: ["f"],
        entirely: true
    ),
    VMSample(
        name: "an enum's methods and a failable initializer",
        source: """
            enum Light: Int {
                case red = 1, green = 2
                var next: Light { self == .red ? .green : .red }
                func weight(_ k: Int) -> Int {
                    switch self {
                    case .red: return rawValue * k
                    case .green: return rawValue + k
                    }
                }
                mutating func advance() { self = next }
            }
            func f() -> Int {
                var l = Light.red
                var t = l.weight(10)
                l.advance()
                t += l.weight(10)
                if let g = Light(rawValue: 2) { t += g.weight(1) }
                if Light(rawValue: 9) == nil { t += 1000 }
                return t
            }
            f()
            """,
        compiles: ["f"],
        entirely: true
    ),
    VMSample(
        name: "a generic function and a generic type's methods",
        source: """
            func pick<T>(_ a: T, _ b: T, _ first: Bool) -> T { first ? a : b }
            struct Stack<Element> {
                var items: [Element] = []
                mutating func push(_ x: Element) { items.append(x) }
                mutating func pop() -> Element? { items.popLast() }
                var count: Int { items.count }
            }
            func total(_ xs: [Int]) -> Int {
                var s = Stack<Int>()
                for x in xs { s.push(x) }
                var t = 0
                while let top = s.pop() { t = t * 2 + top }
                return t + pick(1, 2, false) + s.count
            }
            func label() -> String { pick("a", "b", true) }
            total([1, 2, 3]) + label().count
            """,
        compiles: ["total", "pick", "label"],
        entirely: true
    ),
    VMSample(
        name: "a method that defers, throws and is caught by its caller",
        source: """
            struct Gate {
                var open = false
                var log: [String] = []
                mutating func pass(_ n: Int) throws -> Int {
                    defer { log.append("done \\(n)") }
                    if !open { throw Boom.shut }
                    return n + 1
                }
            }
            enum Boom: Error { case shut }
            func f() -> String {
                var g = Gate()
                var out = ""
                do { _ = try g.pass(1) } catch { out += "shut;" }
                g.open = true
                do { out += "\\(try g.pass(2));" } catch { out += "bad" }
                return out + g.log.joined(separator: ",")
            }
            f()
            """,
        compiles: ["f"],
        entirely: true
    ),
    VMSample(
        name:
            "a mutating method keeps what it changed when it fails, and takes itself as an argument",
        source: """
            struct Counter {
                var n = 0
                var log: [Int] = []
                mutating func bump(_ by: Int) throws {
                    n += by
                    log.append(n)
                    if by > 2 { throw Boom.big }
                }
                mutating func absorb(_ other: Counter) { n += other.n; log += other.log }
            }
            enum Boom: Error { case big }
            func f() -> String {
                var c = Counter()
                var failures = 0
                for i in 0..<6 {
                    do { try c.bump(i) } catch { failures += 1 }
                }
                c.absorb(c)
                var d = c
                d.absorb(c)
                return "\\(c.n) \\(c.log.count) \\(d.n) \\(d.log.count) \\(failures)"
            }
            f()
            """,
        compiles: ["f"],
        entirely: true
    ),
    VMSample(
        name:
            "methods of a global struct: a change kept when the method fails, reads, and a constant",
        source: """
            struct Tally {
                var n = 0
                var log: [Int] = []
                mutating func add(_ by: Int) throws {
                    n += by
                    log.append(n)
                    if by == 3 { throw Stop.now }
                }
                func total() -> Int { n * 2 }
            }
            enum Stop: Error { case now }
            var t = Tally()
            let fixed = Tally()
            var failed = 0
            for i in 0..<6 {
                do { try t.add(i) } catch { failed += 1 }
            }
            func readAll() -> Int { t.total() + fixed.total() + t.log.count }
            print(t.n, t.log, failed, readAll(), fixed.total())
            """,
        compiles: ["readAll"],
        loops: 1
    ),
    VMSample(
        name:
            "initializers over literal defaults and computed ones, and memberwise values of each kind",
        source: """
            var counter = 0
            func next() -> Int { counter += 1; return counter }
            struct A { var a = 1; var b: Int; var c = "c"; init(b: Int) { self.b = b } }
            struct B { var id = next(); var tag: String; init(tag: String) { self.tag = tag } }
            struct C { var xs: [Int]; var o: Int?; var d: Double }
            class K { var n = 1; var m: Int; init(m: Int) { self.m = m } }
            func f(_ n: Int) -> String {
                var out = ""
                for i in 0..<n {
                    let a = A(b: i), b = B(tag: "t\\(i)")
                    let c = C(xs: [i], o: i % 2 == 0 ? i : nil, d: Double(i))
                    let k = K(m: i)
                    out += "\\(a.a + a.b)\\(a.c)\\(b.id)\\(b.tag)\\(c.xs.count)\\(c.o ?? -1)\\(c.d)\\(k.n + k.m);"
                }
                return out
            }
            f(4)
            """,
        compiles: ["f"],
        entirely: true
    ),
    VMSample(
        name:
            "pairs of names over dictionaries of each key kind, lists of tuples and enumerated lists",
        source: """
            func f() -> String {
                var out = ""
                let ints = [3: "c", 1: "a", 2: "b"]
                let words = ["pear": 2, "apple": 1]
                for (k, v) in ints { out += "\\(k)\\(v)" }
                for (k, _) in words { out += k }
                for (_, v) in words { out += "\\(v)" }
                for (k, v) in ints where k > 1 { if v == "b" { continue }; out += "!\\(v)" }
                for (k, v) in ints { if k == 2 { break }; out += "<\\(k)\\(v)>" }
                for (a, b) in [(1, "x"), (2, "y")] { out += "\\(a)\\(b)" }
                for (i, x) in ["p", "q"].enumerated() { out += "\\(i)\\(x)" }
                var total = 0
                var dict: [Int: Int] = [:]
                for i in 0..<5 { dict[i * 7 % 5] = i }
                for (k, v) in dict { total += k * v }
                return out + "\\(total)"
            }
            f()
            """,
        compiles: ["f"],
        entirely: true
    ),
    VMSample(
        name: "sorting numbers, counting in a dictionary with a default, and adding literal lists",
        source: """
            func f(_ n: Int) -> String {
                var out = ""
                let ints = (0..<n).map { ($0 * 7919) % 101 }
                out += "\\(ints.sorted().prefix(5)) \\(ints.sorted().last ?? -1) "
                let doubles = ints.map { Double($0) / 4 }
                out += "\\(doubles.sorted().prefix(3)) "
                let words = ["pear", "apple", "fig"]
                out += "\\(words.sorted()) \\(([] as [Int]).sorted()) \\([3, 1, 2].sorted(by: >)) "
                var counts: [Int: Int] = [:]
                var names: [String: Int] = [:]
                for i in 0..<n {
                    counts[i % 7, default: 0] += 1
                    names["k\\(i % 3)", default: 10] += i
                    counts[i % 7, default: 0] -= i % 2
                }
                out += "\\(counts[0] ?? -1) \\(counts[6] ?? -1) \\(names["k1"] ?? -1) \\(counts.count) "
                var xs: [Int] = []
                var ys = [String]()
                for i in 0..<n {
                    xs += [i]
                    xs += [i * 2, i * 3]
                    xs += []
                    ys += ["a\\(i)"]
                }
                out += "\\(xs.count) \\(xs[xs.count - 1]) \\(ys.joined())"
                return out
            }
            f(6)
            """,
        compiles: ["f"],
        entirely: true
    ),
    VMSample(
        name: "fields and elements changed in place by each plain kind's operators",
        source: """
            struct S { var d = 9.0; var t = "a"; var n = 7; var b = true }
            func f() -> String {
                var s = S()
                s.d /= 2
                s.d -= 0.25
                s.t += "bc"
                s.n %= 4
                s.n *= -3
                s.b = false
                var xs = [1.5, 2.5]
                xs[1] /= 5
                var names = ["x": "p"]
                names["x"]! += "q"
                return "\\(s.d) \\(s.t) \\(s.n) \\(s.b) \\(xs) \\(names)"
            }
            f()
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "a struct held in place by its mutating methods and initializers, through every path",
        source: """
            struct Inner { var count = 0 }
            struct Box {
                var items: [Int] = []
                var inner = Inner()
                var name: String
                init(name: String) { self.name = name }
                init() { self.init(name: "none") }
                mutating func add(_ x: Int) throws {
                    items.append(x)
                    inner.count += 1
                    name = "\\(name)\\(x)"
                    if x > 3 { throw Stop.big }
                    let span = 0...x
                    items.append(span.count)
                }
                mutating func sortDown() { items.sort { $0 > $1 } }
                mutating func reset() { self = Box(name: "reset") }
                mutating func twice(_ x: Int) throws { try add(x); try add(x + 1) }
                mutating func bumpDeep() { self.inner.count += 10 }
            }
            enum Stop: Error { case big }
            func f() -> String {
                var b = Box(name: "b")
                var failed = 0
                for i in 0..<6 {
                    do { try b.twice(i) } catch { failed += 1 }
                }
                b.bumpDeep()
                b.sortDown()
                var log = "\\(b.items) \\(b.inner.count) \\(b.name) \\(failed)"
                b.reset()
                let other = Box()
                log += " \\(b.name) \\(b.items.count) \\(other.name)"
                return log
            }
            var g = Box(name: "g")
            try g.add(1)
            g.bumpDeep()
            print(f(), g.items, g.inner.count, g.name)
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "a method calling a plain function and being called from one",
        source: """
            func double(_ x: Int) -> Int { x * 2 }
            struct Acc {
                var v = 1
                mutating func step(_ k: Int) { v = double(v) + k }
                func read() -> Int { double(v) }
            }
            func run(_ n: Int) -> Int {
                var a = Acc()
                for i in 0..<n { a.step(i) }
                return double(a.read())
            }
            run(5)
            """,
        compiles: ["double", "run"],
        entirely: true
    ),
    VMSample(
        name: "a closure that captures self",
        source: """
            struct Mul {
                var k: Int
                func apply(_ xs: [Int]) -> [Int] { xs.map { $0 * k } }
                func adder() -> (Int) -> Int { { x in x + self.k } }
            }
            func f() -> Int {
                let m = Mul(k: 3)
                let add = m.adder()
                return m.apply([1, 2, 3]).reduce(0, +) + add(10)
            }
            f()
            """,
        compiles: ["f"],
        entirely: true
    ),
]

let vmParameterKinds: [VMSample] = [
    VMSample(
        name: "variadic parameters, called with none, one and several",
        source: """
            func total(_ xs: Int...) -> Int {
                var t = 0
                for x in xs { t += x }
                return t * 10 + xs.count
            }
            func f() -> Int { total(1, 2, 3) + total(5) + total() }
            f()
            """,
        compiles: ["total", "f"]
    ),
    VMSample(
        name: "an autoclosure argument is not evaluated unless the callee asks",
        source: """
            func lazyIf(_ c: Bool, _ v: @autoclosure () -> Int) -> Int { c ? v() : 0 }
            func boom() -> Int { print("evaluated"); return 1 }
            func f() -> Int { lazyIf(false, boom()) + lazyIf(true, boom()) * 10 }
            f()
            """,
        compiles: ["lazyIf", "f"]
    ),
]

let vmFailingKinds: [VMSample] = [
    VMSample(
        name: "an error in a method two calls down",
        source: """
            struct Div {
                var d: Int
                func inner(_ x: Int) -> Int { x / d }
                func outer(_ x: Int) -> Int { inner(x) + 1 }
            }
            func f() -> Int { Div(d: 0).outer(4) }
            f()
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "an initializer that leaves a property unset",
        source: """
            struct Half {
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
        name: "a throwing method called through a function with no handler",
        source: """
            enum Bad: Error { case negative(Int) }
            struct Natural {
                var n: Int
                func checked() throws -> Int {
                    if n < 0 { throw Bad.negative(n) }
                    return n
                }
            }
            func f(_ k: Int) throws -> Int {
                let m = Natural(n: k)
                return try m.checked() + 1
            }
            try f(-3)
            """,
        compiles: ["f"]
    ),
]
