import CryptoKit
import Foundation

public struct FileFingerprint: Codable, Hashable, Sendable {
    public var size: Int64
    public var modifiedAt: Date
    public var sha256: String

    public init(size: Int64, modifiedAt: Date, sha256: String) {
        self.size = size
        self.modifiedAt = modifiedAt
        self.sha256 = sha256
    }
}

public enum Sha256Hex {
    public static func digest(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum FileFingerprinting {
    /// Streams the file in fixed-size chunks so that large transcripts never sit in memory.
    public static func fingerprint(of url: URL, chunkSize: Int = 1 << 20) throws -> FileFingerprint {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        return FileFingerprint(size: size, modifiedAt: modified, sha256: try sha256(of: url, chunkSize: chunkSize))
    }

    public static func sha256(of url: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of the first `bytes` bytes. Used to detect rewritten (not appended) files.
    public static func headDigest(of url: URL, bytes: Int = 4096) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: bytes) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func fileStat(of url: URL) -> (size: Int64, modifiedAt: Date)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return (size, attributes[.modificationDate] as? Date ?? .distantPast)
    }
}
