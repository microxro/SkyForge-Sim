import Testing
import Foundation
@testable import SFContent

@Suite struct TilePackValidationTests {
    func pack(files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sftp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let m = TilePackManifest(name: "t", files: files, attribution: [])
        try JSONEncoder().encode(m).write(to: dir.appendingPathComponent("manifest.json"))
        return dir
    }

    @Test func rejectsTraversalAndMalformedHashes() throws {
        for bad in ["../../etc/passwd", "abc", String(repeating: "A", count: 64), String(repeating: "g", count: 64),
                    String(repeating: "a", count: 65)] {
            let dir = try pack(files: ["https://x/y": bad])
            #expect(throws: TilePackError.self) { _ = try TilePack(root: dir) }
        }
    }

    @Test func acceptsValidHash() throws {
        let dir = try pack(files: ["https://x/y": String(repeating: "a", count: 64)])
        _ = try TilePack(root: dir)
        #expect(TilePack.isValidHash(String(repeating: "0", count: 64)))
    }
}
