import Testing

@testable import Swiit

// A type annotation becomes a script type and comes back as the same annotation.

@Test func aTypeParameterComesBackAsOne() {
    let annotation = TypeAnnotation.functionType(
        [.parameter("Element")],
        .list(.parameter("Element")),
        throws: true,
        async: .sync
    )
    #expect(TypeAnnotation(ScriptType(annotation)) == annotation)
}

@Test(
    arguments: [
        TypeAnnotation.int,
        .optional(.list(.string)),
        .dictionary(.string, .parameter("Value")),
        .generic("Set", [.parameter("Element")]),
        .tuple([
            TypeAnnotation.TupleElement(label: "x", type: .int),
            TypeAnnotation.TupleElement(label: nil, type: .double),
        ]),
        .metatype(.parameter("T")),
        .someSequence(.parameter("E")),
        .functionType([.inOut(.parameter("R")), .int], .bool, throws: false, async: .sync),
        .functionType([.someSequence(.int)], .bool, throws: false, async: .sync),
        .keyPath(.named("Point"), .int),
    ]
)
func anAnnotationSurvivesTheRoundTrip(_ annotation: TypeAnnotation) {
    #expect(TypeAnnotation(ScriptType(annotation)) == annotation)
}
