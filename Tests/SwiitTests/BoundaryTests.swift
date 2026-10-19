@_spi(Layer) @testable import Swiit
import Testing

@Test func theCoreStaysInsideItsBoundaries() throws {
    // The language layers reach the operating system only through Interpreter.Host,
    // and depend on the shell only as far as the ledger records, each with its exit.
    let problems = try Boundaries.violations()
    #expect(problems == [])
}

@Test func theCoresSPIOnlyShrinks() throws {
    // Every `@_spi(Shell) public` declaration is listed in spi-surface.txt:
    // a new one is a decision, and the list goes as they become public API.
    let problems = try SPISurface.differences()
    #expect(problems == [])
}

@Test func theTopLevelOfThePublicAPIIsTheDesignedOne() throws {
    // Everything else an embedder could name is SPI (`@_spi(Layer) public`), listed in spi-surface.txt.
    let current = try PublicSurface.current()
    #expect(current.subtracting(PublicSurface.allowed).sorted() == [], "public, but not in the design")
    #expect(PublicSurface.allowed.subtracting(current).sorted() == [], "in the design, but not public")
}
