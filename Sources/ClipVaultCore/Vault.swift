import Foundation
import CryptoKit
import Darwin

public struct ClipboardEntry: Codable, Identifiable, Equatable {
    public let id: UUID
    public let text: String
    public let createdAt: Date
    public var deletedAt: Date?
    public var name: String?
    public var isSensitive = false

    public init(text: String, createdAt: Date = Date()) {
        id = UUID()
        self.text = text
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey { case id, text, createdAt, deletedAt, name, isSensitive }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        text = try values.decode(String.self, forKey: .text)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        deletedAt = try values.decodeIfPresent(Date.self, forKey: .deletedAt)
        name = try Self.normalizedName(values.decodeIfPresent(String.self, forKey: .name))
        isSensitive = try values.decodeIfPresent(Bool.self, forKey: .isSensitive) ?? false
    }

    static func normalizedName(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.count <= 120, result.utf8.count <= 512, !result.contains(where: \.isNewline) else { throw VaultError.invalidName }
        return result.isEmpty ? nil : result
    }

    func validate() throws {
        guard text.utf8.count <= 1024 * 1024, createdAt.timeIntervalSinceReferenceDate.isFinite else { throw VaultError.invalidFormat }
        guard name == (try Self.normalizedName(name)) else { throw VaultError.invalidName }
    }
}

public struct VaultSettings: Codable, Equatable {
    public var autoLockSeconds: Double = 60
    public var clipboardClearSeconds: Double = 30
    public var historyLimit: Int = 500
    public var retentionDays: Int = 30
    public var ignoreConcealed: Bool = true
    public var excludedApps: [String] = []
    public var captureEnabled: Bool = false

    public init() {}

    public func validated() throws -> Self {
        guard autoLockSeconds.isFinite, (5...86400).contains(autoLockSeconds),
              clipboardClearSeconds.isFinite, (5...3600).contains(clipboardClearSeconds),
              (1...5000).contains(historyLimit), (1...365).contains(retentionDays),
              excludedApps.count <= 100,
              excludedApps.allSatisfy({ !$0.isEmpty && $0.count <= 255 && !$0.contains(where: \.isWhitespace) })
        else { throw VaultError.invalidSettings }
        return self
    }
}

public struct VaultDocument: Codable, Equatable {
    public var entries: [ClipboardEntry] = []
    public var settings = VaultSettings()
    public var capturePrivateKey: Data?
    public var lastImportedSequence: UInt64?
    public init() {}

    public mutating func prune(now: Date, maximumSerializedBytes: Int = EncryptedVaultStore.maximumPlaintextBytes) throws {
        let oldest = now.addingTimeInterval(-Double(settings.retentionDays) * 86400)
        entries = Array(entries.filter { $0.createdAt >= oldest }.prefix(settings.historyLimit))
        var empty = self
        empty.entries = []
        let encoder = JSONEncoder()
        let base = try encoder.encode(empty).count
        var sizes = try entries.map { try encoder.encode($0).count }
        var total = base + sizes.reduce(0, +) + max(0, entries.count - 1)
        while total > maximumSerializedBytes, !entries.isEmpty {
            total -= sizes.removeLast()
            if entries.count > 1 { total -= 1 }
            entries.removeLast()
        }
        guard total <= maximumSerializedBytes else { throw VaultError.invalidFormat }
    }
}

public enum VaultError: LocalizedError {
    case invalidSettings, invalidFormat, invalidName, missingKey, authenticationUnavailable, clipboardWriteFailed, enclaveUnavailable, sessionExpired, inboxFull
    case accessControl(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidSettings: return "Use 5–86,400 seconds for auto-lock, 5–3,600 seconds for clipboard expiry, 1–5,000 items, and 1–365 retention days. Excluded applications need valid bundle IDs."
        case .invalidFormat: return "The vault format is invalid or unsupported. Your encrypted file has not been changed."
        case .invalidName: return "Use a short item name of 120 characters or fewer, on one line."
        case .missingKey: return "The vault exists but its Secure Enclave key envelope is missing. Restore the original key envelope on this Mac. A replacement key will not be created."
        case .enclaveUnavailable: return "ClipVault requires a Mac with a Secure Enclave (Apple silicon or an Intel Mac with a T2 chip). No unprotected key will be created."
        case .authenticationUnavailable: return "Set a Mac login password to use ClipVault. Touch ID is optional."
        case .clipboardWriteFailed: return "macOS could not write to the clipboard."
        case .inboxFull: return "The encrypted capture inbox is full. Unlock your vault to import pending copies."
        case .sessionExpired: return "The vault locked before the operation completed. Unlock to continue."
        case .accessControl(let status): return "Secure Enclave access control could not be configured (\(status)). The vault remains locked."
        }
    }
}

public protocol VaultStorage {
    var exists: Bool { get }
    func load(key: SymmetricKey) throws -> VaultDocument
    func save(_ document: VaultDocument, key: SymmetricKey) throws
    func captureConfiguration() throws -> CaptureConfiguration?
}

public struct EncryptedVaultStore: VaultStorage {
    public let url: URL
    public static let maximumPlaintextBytes = 60 * 1024 * 1024
    private static let legacyHeader = Data("CLIPVAULT1".utf8)
    private static let header = Data("CLIPVAULT2".utf8)
    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    public init(url: URL) { self.url = url }

    public static var applicationURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipVault", isDirectory: true).appendingPathComponent("history.vault")
    }

    public func captureConfiguration() throws -> CaptureConfiguration? {
        guard exists else { return nil }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard let prefix = try file.read(upToCount: Self.header.count), prefix.count == Self.header.count else { throw VaultError.invalidFormat }
        if prefix == Self.legacyHeader { return nil }
        guard prefix == Self.header, let lengthBytes = try file.read(upToCount: 4), lengthBytes.count == 4 else { throw VaultError.invalidFormat }
        let length = lengthBytes.reduce(0) { ($0 << 8) | Int($1) }
        guard (1...65536).contains(length), let bytes = try file.read(upToCount: length), bytes.count == length else { throw VaultError.invalidFormat }
        let configuration = try JSONDecoder().decode(CaptureHeader.self, from: bytes).configuration
        try configuration?.validate()
        return configuration
    }

    private struct CaptureHeader: Codable { let configuration: CaptureConfiguration? }

    public func load(key: SymmetricKey) throws -> VaultDocument {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64 * 1024 * 1024 else { throw VaultError.invalidFormat }
        let data = try Data(contentsOf: url, options: .uncached)
        let authenticatedHeader: Data
        if data.starts(with: Self.legacyHeader) {
            authenticatedHeader = Self.legacyHeader
        } else {
            guard data.starts(with: Self.header), data.count >= Self.header.count + 4 else { throw VaultError.invalidFormat }
            let length = data[Self.header.count..<(Self.header.count + 4)].reduce(0) { ($0 << 8) | Int($1) }
            guard (1...65536).contains(length), data.count >= Self.header.count + 4 + length else { throw VaultError.invalidFormat }
            authenticatedHeader = data.prefix(Self.header.count + 4 + length)
        }
        let box = try AES.GCM.SealedBox(combined: data.dropFirst(authenticatedHeader.count))
        let plaintext = try AES.GCM.open(box, using: key, authenticating: authenticatedHeader)
        let result = try JSONDecoder().decode(VaultDocument.self, from: plaintext)
        _ = try result.settings.validated()
        guard result.entries.count <= 5000 else { throw VaultError.invalidFormat }
        try result.entries.forEach { try $0.validate() }
        if let privateKey = result.capturePrivateKey { _ = try P256.KeyAgreement.PrivateKey(rawRepresentation: privateKey) }
        if data.starts(with: Self.header) {
            let headerBytes = authenticatedHeader.dropFirst(Self.header.count + 4)
            let configuration = try JSONDecoder().decode(CaptureHeader.self, from: headerBytes).configuration
            guard configuration == (try CaptureConfiguration(document: result)) else { throw VaultError.invalidFormat }
        }
        return result
    }

    public func save(_ document: VaultDocument, key: SymmetricKey) throws {
        _ = try document.settings.validated()
        guard document.entries.count <= 5000 else { throw VaultError.invalidFormat }
        try document.entries.forEach { try $0.validate() }
        let plaintext = try JSONEncoder().encode(document)
        guard plaintext.count <= Self.maximumPlaintextBytes else { throw VaultError.invalidFormat }
        let configuration = try CaptureConfiguration(document: document)
        let bytes = try JSONEncoder().encode(CaptureHeader(configuration: configuration))
        guard bytes.count <= 65536 else { throw VaultError.invalidFormat }
        let length = UInt32(bytes.count)
        let lengthBytes = Data([UInt8((length >> 24) & 255), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)])
        let authenticatedHeader = Self.header + lengthBytes + bytes
        let ciphertext = try AES.GCM.seal(plaintext, using: key, authenticating: authenticatedHeader).combined!
        try PrivateFile.write(authenticatedHeader + ciphertext, to: url)
    }

}

enum PrivateFile {
    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = try FileHandle(forWritingTo: temporary)
        do { try file.write(contentsOf: data); try file.synchronize(); try file.close() }
        catch { try? file.close(); throw error }
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
