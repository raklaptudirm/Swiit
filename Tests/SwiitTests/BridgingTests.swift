import Foundation
import Swiit
import Testing

// The conversions generated bridges are made of, called as a bridge written outside Swiit would.

@Test func aBridgeUnwrapsWhatAScriptPassedAndWrapsWhatItGivesBack() throws {
    let swiit = Interpreter()
    let list = try swiit.evaluate("[3, 1, 2]")
    let items = try Value.Bridging.list(list)
    #expect(items.count == 3)
    #expect(try items.map { try Int($0) } == [3, 1, 2])

    let optional = try Value.Bridging.optional(.nothing) { try Int($0) }
    #expect(optional == nil)
    #expect(try Value.Bridging.optional(Value(integerLiteral: 4)) { try Int($0) } == 4)

    let word = try Value.Bridging.sequence(try swiit.evaluate(#""ab""#))
    #expect(word.count == 2)

    #expect(throws: (any Error).self) { try Value.Bridging.list(Value(integerLiteral: 1)) }
}

@Test func aBridgeBoxesARangeAsTheTypeItSaysAndReadsItBack() throws {
    let swiit = Interpreter()
    let boxed = Value.Bridging.box(1...3, as: Symbol.ID(hostType: "ClosedRange")) {
        ClosedRange<Value>(
            uncheckedBounds: (
                Value(integerLiteral: $0.lowerBound), Value(integerLiteral: $0.upperBound)
            )
        )
    }
    let range = try Value.Bridging.closedRange(boxed) { try Int($0) }
    #expect(range == 1...3)
    _ = swiit
}

@Test func aTextLiteralIsOnlyWhatTheTypeCanBe() {
    #expect(Value.Bridging.textLiteral(Character.self, "a") == "a")
    #expect(Value.Bridging.textLiteral(Character.self, "ab") == nil)
}

@Test func foundationsDateWorksThroughItsGeneratedDescription() throws {
    let swiit = Interpreter()
    #expect(try swiit.evaluate("Date(timeIntervalSince1970: 5).timeIntervalSince1970") == 5.0)
    #expect(
        try swiit.evaluate("Date(timeIntervalSince1970: 1) < Date(timeIntervalSince1970: 2)")
            == true
    )
    #expect(
        try swiit.evaluate(
            "Date(timeIntervalSince1970: 3) == Date(timeIntervalSince1970: 3)"
        ) == true
    )
    #expect(
        try swiit.evaluate(
            "(Date(timeIntervalSince1970: 1)...Date(timeIntervalSince1970: 9)).contains(Date(timeIntervalSince1970: 4))"
        ) == true
    )
    #expect(throws: Diagnostic.self) { try swiit.evaluate("Date(timeIntervalSince1970: \"x\")") }
}

@Test func swiftSystemsFilePathChangesInPlaceThroughItsGeneratedDescription() throws {
    let swiit = Interpreter()
    let program = """
        var path: FilePath = "/usr/local"
        path.append("bin")
        path.extension = "txt"
        let last = path.lastComponent!.string
        path.removeLastComponent()
        """
    try swiit.evaluate(program)
    #expect(try swiit.evaluate("path.string") == "/usr/local")
    #expect(try swiit.evaluate("last") == "bin.txt")
}

@Test func aClosureThatChangesSeveralArgumentsLeavesEachChangedValue() throws {
    let swiit = Interpreter()
    let function = try swiit.evaluate(
        "let swapped: (inout Int, Int, inout Int) -> Int = { let t = $0; $0 = $2; $2 = t; return $1 }; swapped"
    )
    let outcome = try Value.Bridging.changing(
        swiit,
        function,
        [Value(integerLiteral: 1), Value(integerLiteral: 2), Value(integerLiteral: 3)],
        at: [0, 2]
    )
    #expect(outcome.result.description == "2")
    #expect(outcome.changed.map(\.description) == ["3", "1"])
}

@Test func reduceIntoChangesItsAccumulatorInPlaceOnEachKindOfSequence() throws {
    let swiit = Interpreter()
    #expect(try swiit.evaluate("[1, 2, 3].reduce(into: 0) { $0 += $1 }").description == "6")
    #expect(try swiit.evaluate("Set([1, 2]).reduce(into: 0) { $0 += $1 }").description == "3")
    #expect(try swiit.evaluate("(1...4).reduce(into: 1) { $0 *= $1 }").description == "24")
    #expect(
        try swiit.evaluate("(0..<3).reduce(into: [Int]()) { $0.append($1 * 2) }").description
            == "[0, 2, 4]"
    )
    #expect(
        try swiit.evaluate(#""abc".reduce(into: "") { $0 = String($1) + $0 }"#).description == "cba"
    )
}

@Test func aVariadicParameterOfAHostFunctionArrivesAsAList() throws {
    let swiit = Interpreter()
    swiit.register(
        HostSymbol.function(
            name: "total",
            parameters: [Symbol.Parameter(name: "values", type: .int, arity: .variadic)],
            returns: .int
        ) { arguments in
            let items = try Value.Bridging.list(arguments[0])
            return Value(integerLiteral: try items.map { try Int($0) }.reduce(0, +))
        }
    )
    #expect(try swiit.evaluate("total(1, 2, 3)").description == "6")
    #expect(try swiit.evaluate("total()").description == "0")
}

@Test func aLazySequenceASwiftMemberGivesIsHeldAsTheArrayItGives() throws {
    let swiit = Interpreter()
    #expect(try swiit.evaluate("zip([1, 2, 3], [\"a\", \"b\"]).count").description == "2")
    #expect(try swiit.evaluate("zip([1, 2], \"xy\").map { $0.1 }").description == "[x, y]")
    #expect(
        try swiit.evaluate("[10, 20].enumerated().map { $0.offset + $0.element }").description
            == "[10, 21]"
    )
    #expect(
        try swiit.evaluate("[3, 1, 2].lazy.map { $0 * 2 }.filter { $0 > 2 }").description
            == "[6, 4]"
    )
    #expect(try swiit.evaluate("(1...4).reversed().map { $0 }").description == "[4, 3, 2, 1]")
    #expect(try swiit.evaluate("[1, 2, 3, 4].prefix(while: { $0 < 3 })").description == "[1, 2]")
    #expect(try swiit.evaluate("[1, 2, 3, 4].drop(while: { $0 < 3 })").description == "[3, 4]")
}

@Test func aSliceASwiftMemberGivesIsHeldAsTheArrayOfItsElements() throws {
    let swiit = Interpreter()
    #expect(try swiit.evaluate("Set([7]).dropFirst(1).count").description == "0")
    #expect(try swiit.evaluate("(1...5).dropFirst(2).map { $0 }").description == "[3, 4, 5]")
    #expect(try swiit.evaluate("(1...5).prefix(2).count").description == "2")
    #expect(try swiit.evaluate("[\"a\": 1].dropLast(1).count").description == "0")
    // A result that is an array of them.
    #expect(
        try swiit.evaluate("[1, 2, 3].split(separator: 2).map { $0.count }").description == "[1, 1]"
    )
}

@Test func aGeneratedFunctionChangesTheVariablesItIsGivenInPlace() throws {
    let swiit = Interpreter()
    #expect(
        try swiit.evaluate("var a = 1; var b = 2; swap(&a, &b); [a, b]").description == "[2, 1]"
    )
    #expect(
        try swiit.evaluate("var xs = [1, 2]; var ys = [3]; swap(&xs, &ys); [xs, ys]").description
            == "[[3], [1, 2]]"
    )
    // Both are the one type, as in Swift.
    #expect(throws: (any Error).self) {
        try swiit.evaluate("var s = \"a\"; var n = 5; swap(&s, &n)")
    }
}

@Test func aStringIsIndexedByItsOwnPositionsThroughTheGeneratedSubscripts() throws {
    let swiit = Interpreter()
    #expect(try swiit.evaluate("let s = \"hello\"; s[s.startIndex]").description == "h")
    #expect(
        try swiit.evaluate("let s = \"hello\"; s[s.index(after: s.startIndex)]").description == "e"
    )
    #expect(
        try swiit
            .evaluate(
                "let s = \"hello\"; let i = s.index(s.startIndex, offsetBy: 1); s[i..<s.endIndex]"
            )
            .description == "ello"
    )
    #expect(
        try swiit
            .evaluate(
                "let s = \"hello\"; let i = s.index(s.startIndex, offsetBy: 1); s[i...i]"
            )
            .description == "e"
    )
    // A Substring is indexed by the same positions.
    #expect(
        try swiit.evaluate("let s = \"hello\"; let t = s.dropFirst(2); t[t.startIndex]").description
            == "l"
    )
    #expect(throws: (any Error).self) {
        try swiit.evaluate("let s = \"hello\"; s[s.endIndex]")
    }
    // An integer is not a position, and the message says what to write.
    do {
        _ = try swiit.evaluate("let s = \"hello\"; s[2]")
        Issue.record("a String was indexed by an Int")
    } catch {
        #expect("\(error)".contains("s.index(s.startIndex, offsetBy: n)"))
    }
}

@Test func aGenericMemberIsBridgedOnceForEachTypeItIsSpecializedTo() throws {
    let swiit = Interpreter()
    // `stride` for Int and for Double.
    #expect(
        try swiit.evaluate("Array(stride(from: 0, to: 10, by: 3))").description == "[0, 3, 6, 9]"
    )
    #expect(
        try swiit.evaluate("Array(stride(from: 0, through: 6, by: 3))").description == "[0, 3, 6]"
    )
    #expect(try swiit.evaluate("Array(stride(from: 3, to: 0, by: -1))").description == "[3, 2, 1]")
    #expect(
        try swiit.evaluate("Array(stride(from: 0.0, to: 1.0, by: 0.5))").description == "[0.0, 0.5]"
    )
    #expect(try swiit.evaluate("for i in stride(from: 0, to: 3, by: 1) { }; 1").description == "1")
    // A step that is zero, or a stride far too long to hold, is an error, not a hang.
    #expect(throws: (any Error).self) { try swiit.evaluate("stride(from: 0, to: 5, by: 0)") }
    #expect(throws: (any Error).self) { try swiit.evaluate("stride(from: 0, to: Int.max, by: 1)") }
    // A subscript by either kind of range.
    #expect(
        try swiit
            .evaluate(
                "let s = \"hello\"; let i = s.index(s.startIndex, offsetBy: 1); s[i...i]"
            )
            .description == "e"
    )
    #expect(
        try swiit
            .evaluate(
                "let s = \"hello\"; let i = s.index(s.startIndex, offsetBy: 1); let t = s[i..<s.endIndex]; t[t.startIndex...t.startIndex]"
            )
            .description == "e"
    )
    #expect(throws: (any Error).self) {
        try swiit.evaluate("let s = \"hi\"; s[s.startIndex...s.endIndex]")
    }
}
