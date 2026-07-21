import Foundation

/// Small shared helper for JSON files stored on disk.
struct JSONFileStorage {
    let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func load<Value: Decodable>(
        _ type: Value.Type,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> Value? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        return try decoder.decode(Value.self, from: Data(contentsOf: fileURL))
    }

    func save<Value: Encodable>(
        _ value: Value,
        encoder: JSONEncoder = JSONEncoder()
    ) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(value).write(to: fileURL, options: .atomic)
    }

    static func applicationSupportFileURL(
        named fileName: String,
        fileManager: FileManager = .default
    ) -> URL {
        let root = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)

        return root
            .appendingPathComponent("CodexPlusBar", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }
}
