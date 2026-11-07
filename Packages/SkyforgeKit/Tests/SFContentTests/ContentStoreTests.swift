import Testing
import Foundation
@testable import SFContent

@Suite struct ContentStoreTests {
    func tempStore() throws -> ContentStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sfcs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return ContentStore(root: dir)
    }

    @Test func knownHash() {
        #expect(ContentID(data: Data("abc".utf8)).hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func putGetDedup() throws {
        let s = try tempStore()
        let id = try s.put(Data("hello".utf8))
        #expect(try s.put(Data("hello".utf8)) == id)
        #expect(try s.get(id) == Data("hello".utf8))
    }

    @Test func byteFlipDetectedAndRemoved() throws {
        let s = try tempStore()
        let id = try s.put(Data(repeating: 7, count: 1024))
        let u = s.url(for: id)
        var d = try Data(contentsOf: u)
        d[10] ^= 0xFF
        try d.write(to: u)
        #expect(throws: ContentError.self) { try s.get(id) }
        #expect(!s.contains(id))
    }
}
