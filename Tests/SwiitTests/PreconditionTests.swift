import Foundation
import Swiit
import Testing

// A Swift member called with an argument it does not accept stops the process, and a trap cannot be
// caught. The generated glue checks first, from `Bridges/preconditions.json`, and a script reads an
// error. If a check were missing here, the test run would end instead of failing: that is the point.

/// What running `source` says went wrong, or nil if it ran.
private func failure(_ source: String) -> String? {
    do {
        _ = try Interpreter().evaluate(source)
        return nil
    } catch {
        return "\(error)"
    }
}

@Test func anIndexOutOfRangeIsAnErrorForEachCollection() {
    let sources = [
        "var a = [1, 2]; a.remove(at: 5)",
        "var a = [1, 2]; a.remove(at: -1)",
        "var a = [1, 2]; a.insert(0, at: 3)",
        "var a = [1, 2]; a.swapAt(0, 5)",
        "var a = [1, 2]; a.removeSubrange(1..<5)",
        "[1, 2].prefix(upTo: 9)",
        "[1, 2].prefix(through: 2)",
        "[1, 2].suffix(from: 3)",
    ]
    for source in sources {
        let message = failure(source)
        #expect(message?.contains("out of") == true, "\(source): \(message ?? "ran")")
    }
}

@Test func aNegativeLengthOrCountIsAnError() {
    let sources = [
        "[1, 2].prefix(-1)", "[1, 2].suffix(-1)", "[1, 2].dropFirst(-1)", "[1, 2].dropLast(-1)",
        "Array(repeating: 0, count: -1)", "[1, 2].split(maxSplits: -1) { $0 == 1 }",
        "var a = [1]; a.reserveCapacity(-1)",
    ]
    for source in sources {
        let message = failure(source)
        #expect(message?.contains("negative") == true, "\(source): \(message ?? "ran")")
    }
}

@Test func removingMoreThanThereIsOrFromNothingIsAnError() {
    #expect(failure("var a: [Int] = []; a.removeFirst()") != nil)
    #expect(failure("var a: [Int] = []; a.removeLast()") != nil)
    #expect(failure("var a = [1, 2]; a.removeFirst(-1)") != nil)
    #expect(failure("var a = [1, 2]; a.removeFirst(3)") != nil)
    #expect(failure("var a = [1, 2]; a.removeLast(3)") != nil)
}

@Test func aStringIndexThatDoesNotFitIsAnError() {
    let sources = [
        "let s = \"abc\"; s.index(after: s.endIndex)",
        "let s = \"abc\"; s.index(before: s.startIndex)",
        "let s = \"abc\"; s.index(s.startIndex, offsetBy: 9)",
        "let s = \"abc\"; s.index(s.startIndex, offsetBy: -1)",
        "let s = \"abc\"; let t = \"abcdef\"; s.distance(from: t.endIndex, to: s.startIndex)",
    ]
    for source in sources {
        #expect(failure(source) != nil, "\(source)")
    }
}

@Test func arithmeticThatWouldTrapIsAnError() {
    #expect(failure("5.quotientAndRemainder(dividingBy: 0)")?.contains("divide") == true)
    #expect(failure("Int.min.quotientAndRemainder(dividingBy: -1)") != nil)
    #expect(failure("Int.max.advanced(by: 1)")?.contains("overflow") == true)
    #expect(failure("Int.min.distance(to: Int.max)")?.contains("overflow") == true)
}

@Test func aRangeWhoseBoundsAreTheWrongWayRoundIsAnError() {
    #expect(
        failure("let a = Date(timeIntervalSince1970: 9); a...Date(timeIntervalSince1970: 0)") != nil
    )
}

@Test func aCallThatIsInRangeStillWorks() throws {
    let swiit = Interpreter()
    #expect(try swiit.evaluate("var a = [1, 2, 3]; a.remove(at: 1); a").description == "[1, 3]")
    #expect(try swiit.evaluate("var a = [1, 3]; a.insert(2, at: 1); a").description == "[1, 2, 3]")
    #expect(try swiit.evaluate("[1, 2, 3].prefix(2)").description == "[1, 2]")
    #expect(try swiit.evaluate("[1, 2, 3].suffix(0)").description == "[]")
    #expect(try swiit.evaluate("var a = [1, 2, 3]; a.removeLast(2); a").description == "[1]")
    #expect(try swiit.evaluate("var a = [1, 2]; a.swapAt(0, 1); a").description == "[2, 1]")
    #expect(
        try swiit.evaluate("let s = \"abc\"; s[s.index(after: s.startIndex)]").description == "b"
    )
    #expect(
        try swiit.evaluate("7.quotientAndRemainder(dividingBy: 2)").description
            == "(quotient: 3, remainder: 1)"
    )
}
