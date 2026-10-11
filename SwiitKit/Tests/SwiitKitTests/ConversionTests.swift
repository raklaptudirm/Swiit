import SwiitKit
import Testing

private struct FileEntry: Encodable {
    struct Owner: Encodable {
        var name: String
        var id: UInt32
    }

    var name: String
    var size: FileSize
    var tags: [String]
    var owner: Owner
    var note: String?
}

@Test func encodesStructsAsTypedRecords() throws {
    let entry = FileEntry(name: "a.txt", size: FileSize(bytes: 1200), tags: ["x"], owner: .init(name: "rak", id: 501), note: nil)
    guard case .record(let record) = try ValueEncoder().encode(entry) else {
        Issue.record("not a record")
        return
    }
    #expect(record.typeName == "FileEntry")
    // Field order follows the declaration; a nil optional is left out, as
    // synthesized Encodable does.
    #expect(record.keys == ["name", "size", "tags", "owner"])
    #expect(record["size"] == .fileSize(FileSize(bytes: 1200)))
    #expect(record["tags"] == .list([.string("x")]))
    guard case .record(let owner)? = record["owner"] else {
        Issue.record("owner isn't a record")
        return
    }
    #expect(owner.typeName == "Owner")
    #expect(owner["id"] == .int(501))
}

@Test func encodesTopLevelArraysAndScalars() throws {
    #expect(try ValueEncoder().encode([1, 2]) == .list([.int(1), .int(2)]))
    #expect(try ValueEncoder().encode("hi") == .string("hi"))
    #expect(throws: EncodingError.self) { try ValueEncoder().encode(UInt64.max) }
}

private final class Node {
    var label = "n"
    var next: Node?
}

@Test func reflectsAnything() {
    let node = Node()
    node.next = node // A cycle, cut off by the depth limit.
    guard case .record(let record) = Value(reflecting: node) else {
        Issue.record("not a record")
        return
    }
    #expect(record.typeName == "Node")
    #expect(record["label"] == .string("n"))
    #expect(Value(reflecting: (1, b: "x")) == .record(Record(["0": .int(1), "b": .string("x")])))
    #expect(Value(reflecting: [UInt8(1)]) == .list([.int(1)]))
    #expect(Value(reflecting: Optional<Int>.none as Any) == .nothing)
}

@Test func recordsKeepOrderButCompareByContent() {
    var record = Record(["b": .int(2), "a": .int(1)])
    #expect(record.keys == ["b", "a"])
    #expect(record == Record(["a": .int(1), "b": .int(2)]))
    record["b"] = nil
    #expect(record.keys == ["a"])
    #expect(Value.record(record).description == "(a: 1)")
}

@Test func formatsFileSizes() {
    #expect(FileSize(bytes: 532).description == "532 B")
    #expect(FileSize(bytes: 1234).description == "1.2 KB")
    #expect(FileSize(bytes: 123_456_789).description == "123 MB")
    #expect(FileSize(bytes: -2000).description == "-2.0 KB")
    // As a value it shows the same.
    #expect(Value.fileSize(FileSize(bytes: 1234)).description == "1.2 KB")
}

@Test func fileSizesParseAndDoArithmetic() throws {
    #expect(FileSize("1024")?.bytes == 1024)
    #expect(FileSize("1.5mb")?.bytes == 1_500_000)
    #expect(FileSize("1.5 MB")?.bytes == 1_500_000)
    #expect(FileSize("2kib")?.bytes == 2048)
    #expect(FileSize("lots") == nil)
    #expect(FileSize(1.5, unit: "gb")?.bytes == 1_500_000_000)
    #expect(FileSize(1, unit: "parsecs") == nil)
    let kb = FileSize(bytes: 1000)
    #expect(try (kb + kb).bytes == 2000)
    #expect(try (kb * 3).bytes == 3000)
    #expect(try (kb / 4).bytes == 250)
    #expect(kb / FileSize(bytes: 500) == 2.0)
    #expect(kb < FileSize(bytes: 1001))
    #expect(throws: SwiitError.self) { try kb / 0 }
    #expect(throws: SwiitError.self) { try FileSize(bytes: .max) * 2 }
}
