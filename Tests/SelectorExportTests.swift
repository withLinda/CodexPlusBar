import Foundation
import Testing
@testable import CodexPlusBar

struct SelectorExportTests {
    private var extensionRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Extensions/expiry-selector")
    }

    @Test
    func crossLanguageFixtureUsesExplicitMillisecondsAndNullEvidence() throws {
        let raw = try Data(contentsOf: extensionRoot.appendingPathComponent("tests/fixtures/selector-v1.json"))
        let snapshot = try SelectorExport.decode(raw)
        #expect(snapshot.accounts.count == 3)
        #expect(snapshot.accounts[0].usage?.observedAtMs == 1_799_999_990_000)
        #expect(snapshot.accounts[2].usage == nil)
        let encoded = try JSONEncoder().encode(snapshot)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
        #expect(object == (try JSONSerialization.jsonObject(with: raw) as? NSDictionary))
        for key in ["password", "refreshToken", "accessToken", "cookie", "otp", "note"] {
            #expect(!String(decoding: encoded, as: UTF8.self).contains("\"\(key)\""))
        }
        try FileManager.default.createDirectory(at: extensionRoot.appendingPathComponent(".runtime"), withIntermediateDirectories: true)
        try encoded.write(to: extensionRoot.appendingPathComponent(".runtime/swift-export.json"))
    }

    @Test
    func atomicPrivateWriteFailurePreservesThePreviousCompleteFile() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = SelectorExportStore(homeDirectory: home)
        let fixture = try SelectorExport.decode(Data(contentsOf: extensionRoot.appendingPathComponent("tests/fixtures/selector-v1.json")))
        try store.write(fixture)
        let before = try Data(contentsOf: store.file)
        let failing = SelectorExportStore(homeDirectory: home, beforeRename: { throw CocoaError(.fileWriteUnknown) })
        #expect(throws: (any Error).self) { try failing.write(fixture) }
        #expect(try Data(contentsOf: store.file) == before)
        #expect((try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: store.file.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.file.deletingLastPathComponent().path) == ["openchamber-selector-v1.json"])
    }
}
