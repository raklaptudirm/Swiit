// The programs of VMTests that use the members of lists and strings the loop makes itself, and the
// cases where it leaves one to the tree evaluator: an empty list, a list of another kind, a constant.

let vmFastMembers: [VMSample] = [
    VMSample(
        name: "append, count and a subscript of a list in a loop",
        source: """
            func f(_ n: Int) -> Int {
                var xs: [Int] = []
                for i in 0..<n { xs.append(i * 2) }
                var t = 0
                for i in 0..<xs.count { t += xs[i] }
                return t + xs.count
            }
            f(50)
            """,
        compiles: ["f"],
        entirely: true
    ),
    VMSample(
        name: "append of a kind the list's first element is not, and to an empty list",
        source: """
            func f() -> Int {
                var ds: [Double] = []
                ds.append(1)
                ds.append(2.5)
                var anys: [Any] = [1]
                anys.append("two")
                anys.append(3.0)
                var opts: [Int?] = [nil]
                opts.append(4)
                var names: [String] = []
                names.append("a")
                names.append("b")
                return ds.count * 1000 + anys.count * 100 + opts.count * 10 + names.count
            }
            f()
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "the length of a string, and an element read through a variable index",
        source: """
            func f(_ s: String, _ k: Int) -> Int {
                var ws = ["a", "bb", "ccc"]
                var t = s.count
                for w in ws { t += w.count }
                ws.append(s)
                return t + ws[k].count + ws.count
            }
            f("hello", 1)
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "a list in a closure's cell is changed through the cell",
        source: """
            func f() -> Int {
                var xs = [1]
                let add = { xs.append(xs.count + 1) }
                add()
                add()
                xs.append(9)
                return xs.count * 10 + xs[2]
            }
            f()
            """,
        compiles: ["f"]
    ),
]

let vmFailingFastMembers: [VMSample] = [
    VMSample(
        name: "a subscript out of range, and a negative one",
        source: """
            func f(_ i: Int) -> Int {
                let xs = [1, 2, 3]
                return xs[i]
            }
            f(-1)
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "append of a string to a list of numbers",
        source: """
            func f() -> Int {
                var xs: [Int] = [1]
                xs.append(Int("x") ?? 0)
                xs.append(xs.count)
                return xs[5]
            }
            f()
            """,
        compiles: ["f"]
    ),
]
