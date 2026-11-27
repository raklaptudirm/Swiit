// The programs of VMTests whose functions declare functions and types in their blocks, which the VM
// binds by name in a scope of the block, as the tree evaluator does.

let vmDeclarations: [VMSample] = [
    VMSample(
        name: "a nested function called in a loop",
        source: """
            func run() -> Int {
                func f(_ x: Int) -> Int { x + 1 }
                var t = 0
                for i in 0..<10 { t += f(i) }
                return t
            }
            run()
            """,
        compiles: ["run"],
        entirely: true
    ),
    VMSample(
        name: "a nested function that changes a local it captured",
        source: """
            func run() -> Int {
                var total = 0
                func add(_ n: Int) { total += n }
                add(1); add(2); add(3)
                return total
            }
            run()
            """,
        compiles: ["run"],
        entirely: true
    ),
    VMSample(
        name: "a nested function that calls itself",
        source: """
            func run() -> Int {
                func fib(_ n: Int) -> Int { n < 2 ? n : fib(n - 1) + fib(n - 2) }
                return fib(15)
            }
            run()
            """,
        compiles: ["run"],
        entirely: true
    ),
    VMSample(
        name: "nested functions that call each other, one declared after the other",
        source: """
            func run() -> Bool {
                func isEven(_ n: Int) -> Bool { n == 0 ? true : isOdd(n - 1) }
                func isOdd(_ n: Int) -> Bool { n == 0 ? false : isEven(n - 1) }
                return isEven(10) && !isOdd(4)
            }
            run()
            """,
        compiles: ["run"],
        entirely: true
    ),
    VMSample(
        name: "a nested function returned, which calls itself after its block ended",
        source: """
            func make() -> (Int) -> Int {
                func countdown(_ n: Int) -> Int { n == 0 ? 0 : 1 + countdown(n - 1) }
                return countdown
            }
            let c = make()
            c(5) + c(3)
            """,
        compiles: ["make"]
    ),
    VMSample(
        name: "a function declared in a loop's body, with each iteration's value",
        source: """
            func run() -> [Int] {
                var made: [() -> Int] = []
                for i in 0..<3 {
                    let k = i * 10
                    func get() -> Int { k + i }
                    made.append(get)
                }
                return made.map { $0() }
            }
            run()
            """,
        compiles: ["run"]
    ),
    VMSample(
        name: "a function declared in an if, and another of the same name in its else",
        source: """
            func pick(_ c: Bool) -> Int {
                if c {
                    func value() -> Int { 1 }
                    return value()
                } else {
                    func value() -> Int { 2 }
                    return value() * 10
                }
            }
            pick(true) + pick(false)
            """,
        compiles: ["pick"],
        entirely: true
    ),
    VMSample(
        name: "a nested struct with a method and an initializer",
        source: """
            func run() -> Int {
                struct P {
                    var x: Int
                    func sum() -> Int { x + 1 }
                }
                var t = 0
                for i in 0..<5 { let p = P(x: i); t += p.sum() }
                return t
            }
            run()
            """,
        compiles: ["run"]
    ),
    VMSample(
        name: "a nested enum switched over",
        source: """
            func run() -> String {
                enum Light { case red, green }
                var out = ""
                for light in [Light.red, .green, .red] {
                    switch light {
                    case .red: out += "r"
                    case .green: out += "g"
                    }
                }
                return out
            }
            run()
            """,
        compiles: ["run"]
    ),
    VMSample(
        name: "a nested function in a method names self",
        source: """
            struct Box {
                var items: [Int]
                func total() -> Int {
                    func weight(_ i: Int) -> Int { items[i] * (i + 1) }
                    var t = 0
                    for i in 0..<items.count { t += weight(i) }
                    return t
                }
            }
            Box(items: [3, 4, 5]).total()
            """,
        compiles: []
    ),
    VMSample(
        name: "an error caught in a block that declares, and the function called after",
        source: """
            enum Oops: Error { case bad }
            func run() -> Int {
                func check(_ x: Int) throws -> Int {
                    if x > 2 { throw Oops.bad }
                    return x
                }
                var t = 0
                for i in 0..<5 {
                    do { t += try check(i) } catch { t += 100 }
                }
                return t + (try! check(1))
            }
            run()
            """,
        compiles: ["run"]
    ),
    VMSample(
        name: "break and continue out of blocks that declare",
        source: """
            func run() -> Int {
                var t = 0
                for i in 0..<10 {
                    func twice(_ x: Int) -> Int { x * 2 }
                    if i == 7 { break }
                    if i % 2 == 0 { continue }
                    t += twice(i)
                }
                func last() -> Int { t }
                return last()
            }
            run()
            """,
        compiles: ["run"],
        entirely: true
    ),
    VMSample(
        name: "a function that declares, called from one that declares the same name",
        source: """
            func inner() -> Int {
                func helper() -> Int { 1 }
                return helper()
            }
            func outer() -> Int {
                func helper() -> Int { 100 }
                return inner() + helper()
            }
            outer() + outer()
            """,
        compiles: ["inner", "outer"],
        entirely: true
    ),
    VMSample(
        name: "a top-level loop whose body declares a function",
        source: """
            var t = 0
            for i in 0..<4 {
                func sq(_ x: Int) -> Int { x * x }
                t += sq(i)
            }
            t
            """,
        compiles: [],
        loops: 1
    ),
]
