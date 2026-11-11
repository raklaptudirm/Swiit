import Testing

@Test func aLayerNamesNothingAboveIt() throws {
    // The model is what every layer shares, so it names none of them; the syntax tree names only
    // the model. A new dependency upward fails here, and is a decision.
    let problems: [String]
    do { problems = try Layering.violations() } catch {
        Issue.record("\(error)")
        return
    }
    #expect(problems == [])
}
