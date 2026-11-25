// The programs of VMTests that use what slice 7 of Docs/vm.md compiled: the loops of a program's own
// code, whose variables are globals by name and whose blocks' locals are registers.

let vmTopLevel: [VMSample] = [
    VMSample(
        name: "a while and a for at the top level over globals",
        source: """
            var total = 0
            var i = 0
            while i < 50 { total += i; i += 1 }
            for k in 0..<20 { total += k * 2 }
            print(total, i)
            total
            """,
        compiles: [],
        loops: 2
    ),
    VMSample(
        name: "a top-level loop calling functions, with break, continue and a label",
        source: """
            func sq(_ n: Int) -> Int { n * n }
            var seen: [Int] = []
            outer: for a in 1...6 {
                for b in 1...6 {
                    if b == 3 { continue }
                    if a * b > 20 { break outer }
                    seen.append(sq(a) + b)
                }
            }
            print(seen)
            seen.count
            """,
        compiles: ["sq"],
        loops: 1
    ),
    VMSample(
        name: "closures made in a top-level loop keep the variable they were made with",
        source: """
            var fs: [() -> Int] = []
            for i in 0..<4 {
                let j = i * 10
                fs.append { j + i }
            }
            var t = 0
            for f in fs { t += f() }
            t
            """,
        compiles: [],
        loops: 2
    ),
    VMSample(
        name: "a loop in a program that also declares types and functions after it",
        source: """
            var n = 0
            for i in 0..<5 { n += later(i) }
            func later(_ x: Int) -> Int { Box(v: x).v + 1 }
            struct Box { var v: Int }
            n
            """,
        // Declared again where it is written, which the loop has not reached: the one that ran is not the
        // one the program ends with.
        compiles: [],
        loops: 1
    ),
    VMSample(
        name: "a top-level for over a dictionary and a string",
        source: """
            let d = ["a": 1, "b": 2]
            var s = ""
            for (k, v) in d { s += k + String(v) }
            for c in "xyz" { s += String(c) }
            s
            """,
        compiles: [],
        loops: 2
    ),
]

let vmFailingTopLevel: [VMSample] = [
    VMSample(
        name: "an error in a function called from a top-level loop",
        source: """
            func d(_ x: Int) -> Int { 10 / x }
            var t = 0
            for i in (0..<3).reversed() { t += d(i) }
            t
            """,
        compiles: ["d"],
        loops: 1
    ),
    VMSample(
        name: "an error in the loop's own body",
        source: """
            var xs = [1, 2, 3]
            var i = 0
            while true { i += 1; xs[i] += 1 }
            """,
        compiles: [],
        loops: 1
    ),
]
