import Foundation
import CryptoKit

/// Store private drafts with iOS data protection, excluded from cloud backups.
struct LocalStore {
    private func url(_ name: String) throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
            .appendingPathComponent("TriliumPocket", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var directory = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return root.appendingPathComponent(name + ".json")
    }
    func load<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        guard let file = try? url(name), let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    func save<T: Encodable>(_ value: T, name: String) throws {
        try JSONEncoder().encode(value).write(to: url(name), options: [.atomic, .completeFileProtection])
    }
    func remove(_ name: String) throws {
        let file = try url(name)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    static func scopedName(_ prefix: String, server: String, noteID: String = "") -> String {
        // Fixed-size names avoid filesystem limits and separate each server's drafts.
        let key = SHA256.hash(data: Data((server + "|" + noteID).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return prefix + "-" + key
    }
}
