@_spi(Shell) @testable import Swiit
import Testing

@Test func theCoreStaysInsideItsBoundaries() throws {
    // The language layers reach the operating system only through SwishHost,
    // and depend on the shell only as far as the ledger records, each with its exit.
    let problems = try Boundaries.violations()
    #expect(problems == [])
}
