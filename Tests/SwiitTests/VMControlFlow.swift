// The programs of VMTests that use what slice 2 of Docs/vm.md compiled: switch, if let and if case,
// guard, throw, do and catch, try, and defer.

let vmControlFlow: [VMSample] = [
    VMSample(
        name: "switch over ints, ranges and a default",
        source: """
            func grade(_ n: Int) -> String {
                switch n {
                case 0: return "zero"
                case 1...9: return "small"
                case 10, 20, 30: return "round"
                default: return "big"
                }
            }
            [grade(0), grade(5), grade(20), grade(99)]
            """,
        compiles: ["grade"]
    ),
    VMSample(
        name: "switch over an enum with payloads and a where",
        source: """
            enum Shape { case circle(Int), rect(Int, Int), none }
            func area(_ s: Shape) -> Int {
                switch s {
                case .circle(let r) where r > 5: return -1
                case .circle(let r): return 3 * r * r
                case .rect(let w, let h): return w * h
                case .none: return 0
                }
            }
            area(.circle(2)) + area(.circle(9)) + area(.rect(2, 3)) + area(.none)
            """,
        compiles: ["area"]
    ),
    VMSample(
        name: "switch with fallthrough and break",
        source: """
            func f(_ n: Int) -> Int {
                var t = 0
                switch n {
                case 1: t += 1; fallthrough
                case 2: t += 10
                case 3:
                    if n > 2 { break }
                    t += 100
                default: t = -1
                }
                return t
            }
            [f(1), f(2), f(3), f(4)]
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "switch over a tuple and a string",
        source: """
            func g(_ p: (Int, Int)) -> Int {
                switch p {
                case (0, 0): return 1
                case (let x, 0): return x + 10
                case (_, let y) where y > 5: return 100
                default: return 0
                }
            }
            func h(_ s: String) -> Int {
                switch s { case "a": return 1; case "b", "c": return 2; default: return 0 }
            }
            g((0, 0)) + g((3, 0)) + g((1, 9)) + g((1, 1)) + h("c") + h("z")
            """,
        compiles: ["g", "h"]
    ),
    VMSample(
        name: "if let, if case and guard",
        source: """
            func a(_ x: Int?) -> Int { if let v = x { return v + 1 } else { return -1 } }
            func b(_ x: Int?) -> Int { guard let v = x else { return -1 }; return v * 2 }
            enum E { case ok(Int), bad }
            func c(_ e: E) -> Int { if case .ok(let n) = e { return n }; return 0 }
            func d(_ e: E) -> Int { guard case .ok(let n) = e else { return -1 }; return n + 100 }
            func e(_ n: Int) -> Int { guard n > 2 else { return 0 }; return n }
            a(1) + a(nil) + b(2) + b(nil) + c(.ok(5)) + c(.bad) + d(.ok(1)) + d(.bad) + e(1) + e(7)
            """,
        compiles: ["a", "b", "c", "d", "e"]
    ),
    VMSample(
        name: "guard in a loop",
        source: """
            func f(_ xs: Int) -> Int {
                var t = 0
                for i in 0..<xs {
                    guard i % 2 == 0 else { continue }
                    t += i
                }
                return t
            }
            f(10)
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "throw and catch",
        source: """
            enum Oops: Error { case bad(Int), worse }
            func risky(_ n: Int) throws -> Int {
                if n > 5 { throw Oops.bad(n) }
                if n < 0 { throw Oops.worse }
                return n * 2
            }
            func safe(_ n: Int) -> Int {
                do {
                    return try risky(n)
                } catch Oops.bad(let m) {
                    return m + 1000
                } catch {
                    return -1
                }
            }
            safe(2) + safe(9) + safe(-1)
            """,
        compiles: ["risky", "safe"]
    ),
    VMSample(
        name: "an error nobody caught goes on",
        source: """
            enum Oops: Error { case a, b }
            func thrower() throws { throw Oops.b }
            func narrow() -> Int {
                do { try thrower(); return 0 } catch Oops.a { return 1 } catch { return 2 }
            }
            func narrower() throws -> Int {
                do { try thrower(); return 0 } catch Oops.a { return 1 }
            }
            func outer() -> Int {
                do { return try narrower() } catch { return 3 }
            }
            narrow() + outer()
            """,
        compiles: ["thrower", "narrow", "narrower", "outer"]
    ),
    VMSample(
        name: "try? and try!",
        source: """
            enum Oops: Error { case a }
            func f(_ n: Int) throws -> Int { if n == 0 { throw Oops.a }; return n }
            func g(_ n: Int) -> Int { return (try? f(n)) ?? -1 }
            func h(_ n: Int) -> Int { return try! f(n) }
            g(0) + g(3) + h(4)
            """,
        compiles: ["g", "h"]
    ),
    VMSample(
        name: "a runtime failure is caught",
        source: """
            func div(_ a: Int, _ b: Int) -> Int { return a / b }
            func safe(_ a: Int, _ b: Int) -> Int {
                do { return div(a, b) } catch { return -7 }
            }
            safe(6, 3) + safe(1, 0)
            """,
        compiles: ["div", "safe"]
    ),
    VMSample(
        name: "defer runs last first when a block ends",
        source: """
            func f() -> Int {
                var log = 0
                do {
                    defer { log = log * 10 + 1 }
                    defer { log = log * 10 + 2 }
                    log = 5
                }
                return log
            }
            f()
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "defer after an early return, and on return",
        source: """
            var trail = 0
            func early(_ n: Int) -> Int {
                defer { trail = trail * 10 + 1 }
                if n > 0 { return 1 }
                defer { trail = trail * 10 + 2 }
                return 0
            }
            _ = early(1); _ = early(0)
            trail
            """,
        compiles: []
    ),
    VMSample(
        name: "defer with break, continue and a thrown error",
        source: """
            enum Oops: Error { case x }
            func loop() -> Int {
                var trail = 0
                for i in 0..<4 {
                    defer { trail = trail * 10 + i }
                    if i == 1 { continue }
                    if i == 3 { break }
                    trail = trail * 10 + 7
                }
                return trail
            }
            func failing() throws { throw Oops.x }
            func wrap() -> Int {
                do { try failing() } catch { return 5 }
                return 0
            }
            loop() + wrap()
            """,
        compiles: ["loop", "failing", "wrap"]
    ),
    VMSample(
        name: "nested do and catch, and a throw from a catch",
        source: """
            enum Oops: Error { case a, b }
            func f(_ n: Int) -> Int {
                do {
                    do {
                        if n == 1 { throw Oops.a }
                        if n == 2 { throw Oops.b }
                        return 0
                    } catch Oops.a {
                        throw Oops.b
                    }
                } catch Oops.b {
                    return 20
                } catch {
                    return 30
                }
            }
            f(0) + f(1) + f(2)
            """,
        compiles: ["f"]
    ),
]

let vmMoreControlFlow: [VMSample] = [
    VMSample(
        name: "an error in a defer is reported and the others still run",
        source: """
            func f(_ z: Int) -> Int {
                var t = 1
                defer { t = t + 1 }
                defer { let r = 10 / z; t = r }
                defer { t = t * 5 }
                return t
            }
            f(0) + f(2)
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "continue and break in a switch in a loop",
        source: """
            func f(_ n: Int) -> Int {
                var t = 0
                for i in 0..<n {
                    switch i % 3 {
                    case 0: continue
                    case 1: t += 10
                    default: break
                    }
                    t += 1
                }
                return t
            }
            f(10)
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "try? in a loop with a do and catch that continues",
        source: """
            enum Oops: Error { case odd }
            func check(_ n: Int) throws -> Int { if n % 2 == 1 { throw Oops.odd }; return n }
            func f(_ n: Int) -> Int {
                var t = 0
                for i in 0..<n {
                    t += (try? check(i)) ?? 100
                    do { let v = try check(i); t += v } catch { continue }
                    t += 1000
                }
                return t
            }
            f(6)
            """,
        compiles: ["check", "f"]
    ),
]

let vmFailingControlFlow: [VMSample] = [
    VMSample(
        name: "a switch that matches nothing",
        source: """
            func f(_ n: Int) -> Int { switch n { case 1: return 1; case 2: return 2; default: break }; return 0 }
            func g(_ n: Int) -> Int { switch n { case 1: return 1 } }
            f(1) + g(3)
            """,
        compiles: ["f", "g"]
    ),
    VMSample(
        name: "an uncaught throw two calls down",
        source: """
            enum Oops: Error { case x }
            func inner() throws { throw Oops.x }
            func middle() throws { try inner() }
            func outer() throws { try middle() }
            try outer()
            """,
        compiles: ["inner", "middle", "outer"]
    ),
    VMSample(
        name: "an error in the middle of a function with a defer",
        source: """
            var trail = 0
            func f(_ z: Int) -> Int {
                defer { trail = trail + 1 }
                let v = 5 / z
                return v
            }
            func g(_ z: Int) -> Int { return f(z) }
            g(0)
            """,
        compiles: []
    ),
    VMSample(
        name: "try! on a failing call stops the script",
        source: """
            enum Oops: Error { case x }
            func f() throws { throw Oops.x }
            func g() { try! f() }
            g()
            """,
        compiles: ["f", "g"]
    ),
]
