import Foundation
import Testing
@testable @_spi(Layer) @_spi(Host) import Swiit

// Where time must not go: a script that builds a collection one element at a time has to be linear, not
// quadratic. A copy of the whole collection on each call is what these catch; the limits are loose so only that fails.

private func seconds(_ source: String) throws -> Double {
    let host = SwiitHost(output: OutputSink(write: { _ in true }), error: OutputSink(write: { _ in true }))
    let interpreter = Interpreter(host: host, limits: Limits())
    let start = Date()
    _ = try interpreter.eval(source)
    return Date().timeIntervalSince(start)
}

@Test func appendingToAListCostsTheElementNotTheList() throws {
    // 50 000 appends: a copy each time would be over a billion element copies.
    let time = try seconds("var xs: [Int] = []\nfor i in 0..<50000 { xs.append(i) }\nxs.count")
    #expect(time < 10)
}

@Test func addingToASetOrAStringCostsTheElementToo() throws {
    let time = try seconds("var s = Set<Int>()\nfor i in 0..<30000 { s.insert(i) }\nvar t = \"\"\nfor i in 0..<30000 { t.append(\"x\") }\ns.count + t.count")
    #expect(time < 10)
}

@Test func changingAnElementInPlaceCostsTheElementToo() throws {
    let source = """
    var xs = Array(repeating: 0, count: 30000)
    for i in 0..<30000 { xs[i] = i }
    var d: [Int: Int] = [:]
    for i in 0..<30000 { d[i] = i }
    var ys: [Int] = []
    for i in 0..<30000 { ys += [i] }
    var counts: [String: Int] = [:]
    for i in 0..<30000 { counts["k\\(i % 50)", default: 0] += 1 }
    xs.count + d.count + ys.count + counts.count
    """
    #expect(try seconds(source) < 10)
}

@Test func aCollectionInsideAStructIsChangedInPlaceToo() throws {
    let source = """
    struct Bag { var items: [Int] = []; var total = 0 }
    var bag = Bag()
    for i in 0..<30000 { bag.items.append(i); bag.total += i }
    for i in 0..<30000 { bag.items[i] = 0 }
    bag.items.count
    """
    #expect(try seconds(source) < 10)
}

@Test func changesInPlaceKeepTheValuesRight() throws {
    // What moving a value out and back must not break: the variable after an error, reads of it in the right side.
    let host = SwiitHost(output: OutputSink(write: { _ in true }), error: OutputSink(write: { _ in true }))
    let interpreter = Interpreter(host: host, limits: Limits())
    let value = try interpreter.eval("""
    var xs = [1, 2, 3]
    xs[0] = xs[1] + xs[2]
    xs += [xs.count]
    var d: [String: [Int]] = [:]
    d["a", default: []].append(1)
    d["a", default: []].append(2)
    struct Box { var items: [Int] = [] }
    var box = Box()
    box.items.append(xs[0])
    box.items += xs
    [xs, box.items, d["a"] ?? []]
    """)
    #expect("\(value)" == "[[5, 2, 3, 3], [5, 5, 2, 3, 3], [1, 2]]")
    // An index out of range is an error, and leaves the list as it was.
    #expect(throws: (any Error).self) { _ = try interpreter.eval("xs[9] = 1") }
    #expect("\(try interpreter.eval("xs"))" == "[5, 2, 3, 3]")
}
