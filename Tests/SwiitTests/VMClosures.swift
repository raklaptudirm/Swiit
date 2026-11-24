// The programs of VMTests that use what slice 3 of Docs/vm.md compiled: closures and the variables
// they capture, calls through a value, `inout`, and assignment to what is not a local.

let vmClosures: [VMSample] = [
    VMSample(
        name: "a counter a function makes",
        source: """
            func makeCounter() -> () -> Int { var n = 0; return { n += 1; return n } }
            let c = makeCounter()
            let d = makeCounter()
            c() + c() + d() + c()
            """,
        compiles: ["makeCounter", "c", "d"]
    ),
    VMSample(
        name: "a closure given to a function that calls it",
        source: """
            func apply(_ f: (Int) -> Int, _ x: Int) -> Int { return f(x) + f(x + 1) }
            func run(_ k: Int) -> Int { return apply({ $0 * k }, 3) }
            run(5)
            """,
        compiles: ["apply", "run"]
    ),
    VMSample(
        name: "a closure that changes a captured variable",
        source: """
            func f() -> Int {
                var total = 0
                let add = { (n: Int) in total += n }
                add(1); add(2); add(3)
                return total
            }
            f()
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "closures in closures",
        source: """
            func f() -> Int {
                var n = 0
                let inc = { n += 1 }
                let twice = { inc(); inc() }
                twice(); twice()
                return n
            }
            f()
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "a capture list takes the value when the closure is made",
        source: """
            func f() -> Int {
                var x = 1
                let g = { [x] in x * 10 }
                x = 5
                return g() + x
            }
            f()
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "a weak capture of an instance",
        source: """
            class Box { var v = 7 }
            func f() -> Int {
                let b = Box()
                let g = { [weak b] in b?.v ?? -1 }
                return g()
            }
            f()
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "a variable of each pass of a loop",
        source: """
            func f() -> Int {
                var closures: [() -> Int] = []
                for i in 0..<3 { closures.append({ i * 10 }) }
                return closures[0]() + closures[2]()
            }
            f()
            """,
        compiles: []
    ),
    VMSample(
        name: "a closure made in a loop and called there",
        source: """
            func f(_ n: Int) -> Int {
                var t = 0
                for i in 0..<n {
                    let g = { (k: Int) in i * k }
                    t += g(2) + g(3)
                }
                return t
            }
            f(4)
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "inout parameters and arguments",
        source: """
            func swap2(_ a: inout Int, _ b: inout Int) { let t = a; a = b; b = t }
            func inc(_ x: inout Int) { x += 1 }
            func f() -> Int {
                var p = 1
                var q = 2
                swap2(&p, &q)
                inc(&p); inc(&p)
                return p * 10 + q
            }
            f()
            """,
        compiles: ["swap2", "inc", "f"]
    ),
    VMSample(
        name: "inout of a variable a closure shares",
        source: """
            func inc(_ x: inout Int) { x += 1 }
            func g() -> Int {
                var n = 0
                let c = { n += 100 }
                inc(&n)
                c()
                inc(&n)
                return n
            }
            g()
            """,
        compiles: ["inc", "g"]
    ),
    VMSample(
        name: "assigning a global",
        source: """
            var counter = 0
            func bump(_ by: Int) { counter += by; counter = counter * 2 }
            bump(1); bump(2)
            counter
            """,
        compiles: ["bump"]
    ),
    VMSample(
        name: "a closure that calls a function and is called by one",
        source: """
            func sq(_ x: Int) -> Int { return x * x }
            func twice(_ f: (Int) -> Int, _ x: Int) -> Int { return f(f(x)) }
            func g(_ k: Int) -> Int { return twice({ sq($0) + k }, 2) }
            g(1)
            """,
        compiles: ["sq", "twice", "g"]
    ),
    VMSample(
        name: "an error in a closure caught by the function that made it",
        source: """
            func g(_ d: Int) -> Int {
                let f = { (x: Int) in 100 / x }
                do { return f(d) } catch { return -5 }
            }
            g(0) + g(4)
            """,
        compiles: ["g"]
    ),
]

let vmFailingClosures: [VMSample] = [
    VMSample(
        name: "an error in a closure called through a function",
        source: """
            func apply(_ f: (Int) -> Int, _ x: Int) -> Int { return f(x) }
            func g(_ d: Int) -> Int { return apply({ 10 / $0 }, d) }
            g(0)
            """,
        compiles: ["apply", "g"]
    )
]
