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
]
