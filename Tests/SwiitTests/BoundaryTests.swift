@testable import Swiit
import Testing

@Test func theCoreStaysInsideItsBoundaries() throws {
    // The language layers reach the operating system only through Interpreter.Host,
    // and depend on the shell only as far as the ledger records, each with its exit.
    let problems = try Boundaries.violations()
    #expect(problems == [])
}

@Test func theTopLevelOfThePublicAPIIsTheDesignedOne() throws {
    let current = try PublicSurface.current()
    #expect(current.subtracting(PublicSurface.allowed).sorted() == [], "public, but not in the design")
    #expect(PublicSurface.allowed.subtracting(current).sorted() == [], "in the design, but not public")
}
