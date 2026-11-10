import Foundation
final class LocalMemory {
    private let directory: URL
    init(directory: URL = AppPaths.root) { self.directory = directory }
    private func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
    func load<T: Decodable>(_ type: T.Type, name: String, fallback: T) -> T {
        guard let data = try? Data(contentsOf: file(name)), let value = try? JSONDecoder().decode(type, from: data) else { return fallback }; return value
    }
    func save<T: Encodable>(_ value: T, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: file(name), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(name).path)
    }
    func delete(_ name: String) throws { if FileManager.default.fileExists(atPath: file(name).path) { try FileManager.default.removeItem(at: file(name)) } }
}
