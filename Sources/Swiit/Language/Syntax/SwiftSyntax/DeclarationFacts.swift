/// What the declarations seen so far say, for the code that comes before or
/// after them: a class's place among the classes, a builder's name, which
/// enums are generic, which globals are computed.
struct DeclarationFacts {
    /// A class's superclass, as written.
    var superclass: [String: String] = [:]
    /// The instance variables and methods a class declares itself.
    var instanceMembers: [String: Set<String>] = [:]
    var resultBuilders: Set<String> = []
    var genericEnums: Set<String> = []
    /// Protocols the program declares: a host's type that holds something (`Job<Int>`) keeps what it holds.
    var protocols: Set<String> = []
    var computedGlobals: Set<String> = []
}
