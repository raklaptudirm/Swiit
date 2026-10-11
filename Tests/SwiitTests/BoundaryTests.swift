@_spi(Layer) @_spi(Swiit) @testable import Swiit
import Testing

@Test func theCoreStaysInsideItsBoundaries() throws {
    // The language layers reach the operating system only through SwiitHost,
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
