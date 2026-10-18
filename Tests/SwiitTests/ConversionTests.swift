@testable import Swiit
import Testing

private struct FileEntry: Encodable {
    struct Owner: Encodable {
        var name: String
        var id: UInt32
    }

    var name: String
    var size: Int
    var tags: [String]
    var owner: Owner
    var note: String?
}

@Test func encodesStructsAsTypedRecords() throws {
    let entry = FileEntry(name: "a.txt", size: 1200, tags: ["x"], owner: .init(name: "rak", id: 501), note: nil)
    guard case .record(let record) = try ValueEncoder().encode(entry) else {
        Issue.record("not a record")
        return
    }
    #expect(record.typeName == "FileEntry")
    // Field order follows the declaration; a nil optional is left out, as
    // synthesized Encodable does.
    #expect(record.keys == ["name", "size", "tags", "owner"])
    #expect(record["size"] == .int(1200))
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
