import Testing

private let reset = "\u{1B}[0m"
private func code(_ text: String) -> String { "\u{1B}[36m\(text)\(reset)" }
private func bold(_ text: String) -> String { "\u{1B}[1m\(text)\(reset)" }
private func italic(_ text: String) -> String { "\u{1B}[3m\(text)\(reset)" }
private func underline(_ text: String) -> String { "\u{1B}[4m\(text)\(reset)" }

@Test func codeStrongEmphasisAndLinksAreStyles() {
    #expect(documentation("a `b` **c** _d_ *e* [f](http://g)").colored
        == "a \(code("b")) \(bold("c")) \(italic("d")) \(italic("e")) \(underline("f"))")
    // Anywhere without colors it's the words.
    #expect(documentation("a `b` **c** _d_ *e* [f](http://g)").plain == "a b c d e f")
}

@Test func codeSpansAreWhatsBetweenEqualRunsOfBackticks() {
    // Double backticks are how DocC links a symbol, and can hold a backtick.
    #expect(documentation("see ``Foo`` and ``a`b``").colored == "see \(code("Foo")) and \(code("a`b"))")
    // Nothing inside is read: no emphasis, no escapes.
    #expect(documentation("`**x** \\n`").plain == "**x** \\n")
    // One space off each end if there's one on both, so a span can start or end with a backtick.
    #expect(documentation("`` `a` ``").plain == "`a`")
    // Never closed: backticks are backticks.
    #expect(documentation("a ` b").plain == "a ` b")
}

@Test func stylesNestAndEscapesWriteTheCharacter() {
    #expect(documentation("**the `x` of it**").colored == "\(bold("the "))\(code("x"))\(bold(" of it"))")
    #expect(documentation("_a **b** c_").colored == "\(italic("a "))\(bold("b"))\(italic(" c"))")
    #expect(documentation("\\*not\\* \\`code\\` \\[x\\](y)").plain == "*not* `code` [x](y)")
    #expect(documentation("[`code` link](u)").colored == "\(code("code"))\(underline(" link"))")
}

@Test func whatMarkdownDoesntTakeForItsOwnStays() {
    // Angle brackets and brackets, as in a signature or a type.
    #expect(documentation("to <dir>, or [Element] back").plain == "to <dir>, or [Element] back")
    // An underscore inside a word, and a star between spaces.
    #expect(documentation("snake_case_name and 2 * 3 * 4").plain == "snake_case_name and 2 * 3 * 4")
    // A delimiter that's never closed, or can't open or close.
    #expect(documentation("**never closed").plain == "**never closed")
    #expect(documentation("a _ b _ c").plain == "a _ b _ c")
    #expect(documentation("a [b] (c)").plain == "a [b] (c)")
    // Whitespace, newlines included, is kept; the empty string is empty.
    #expect(documentation("a  b\nc").plain == "a  b\nc")
    #expect(documentation("").plain == "")
    // A lone backslash is a backslash.
    #expect(documentation("a \\ b\\").plain == "a \\ b\\")
}
