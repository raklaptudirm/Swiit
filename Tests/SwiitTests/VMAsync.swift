// The programs of VMTests that use what slice 6 of Docs/vm.md compiled: `async` functions, `await`,
// `async let`, task groups and `for await`.

let vmAsync: [VMSample] = [
    VMSample(
        name: "async functions awaited in a loop",
        source: """
            func double(_ n: Int) async -> Int { n * 2 }
            func f(_ x: Int) async -> Int {
                var t = 0
                for i in 0..<x { t += await double(i) }
                return t
            }
            await f(6)
            """,
        compiles: ["double", "f"]
    ),
    VMSample(
        name: "async let, read after other work",
        source: """
            func slow(_ n: Int) async -> Int { n + 1 }
            func f() async -> Int {
                async let a = slow(1)
                async let b = slow(2)
                let c = await slow(3)
                return await a * 100 + b * 10 + c
            }
            await f()
            """,
        compiles: ["slow", "f"]
    ),
    VMSample(
        name: "an async let never read ends with the function that made it",
        source: """
            func slow(_ n: Int) async -> Int {
                try? await Task.sleep(nanoseconds: 1_000_000_000_000)
                return n
            }
            func f() async -> Int {
                async let a = slow(1)
                return 5
            }
            await f()
            """,
        // `slow` is cancelled before it starts.
        compiles: ["f"]
    ),
    VMSample(
        name: "a task group read with for await",
        source: """
            func total(_ n: Int) async -> Int {
                await withTaskGroup(of: Int.self) { group in
                    for i in 1...n { group.addTask { i * i } }
                    var t = 0
                    for await v in group { t += v }
                    return t
                }
            }
            func f() async -> Int { await total(4) + 1 }
            await f()
            """,
        compiles: ["total", "f"]
    ),
    VMSample(
        name: "for await over a sequence that makes its own async iterator",
        source: """
            final class Ticker {
                var n: Int
                init(n: Int) { self.n = n }
                func next() async -> Int? {
                    if n == 0 { return nil }
                    n -= 1
                    return n + 1
                }
            }
            struct Countdown {
                var from: Int
                func makeAsyncIterator() -> Ticker { Ticker(n: from) }
            }
            func f() async -> Int {
                var t = 0
                for await v in Countdown(from: 4) { t = t * 10 + v }
                return t
            }
            await f()
            """,
        compiles: ["f"]
    ),
    VMSample(
        name: "an async method on a struct that throws, caught by its caller",
        source: """
            struct Bad: Error {}
            struct Source {
                var limit: Int
                func read(_ n: Int) async throws -> Int {
                    if n > limit { throw Bad() }
                    return n
                }
            }
            func f() async -> Int {
                let source = Source(limit: 2)
                var t = 0
                for i in 1...4 {
                    do { t += try await source.read(i) } catch { t += 100 }
                }
                return t
            }
            await f()
            """,
        compiles: ["f"]
    ),
]

let vmAsyncFailing: [VMSample] = [
    VMSample(
        name: "an error thrown in an async let and awaited",
        source: """
            struct Bad: Error {}
            func boom() async throws -> Int { throw Bad() }
            func f() async throws -> Int {
                async let a = boom()
                return try await a
            }
            try await f()
            """,
        compiles: ["boom", "f"]
    )
]
