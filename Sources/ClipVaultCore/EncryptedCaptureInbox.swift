import Foundation
import CryptoKit

public struct CapturePolicy: Codable, Equatable {
    public let enabled: Bool
    public let ignoreConcealed: Bool
    public let excludedApps: [String]
    public let historyLimit: Int
    public let retentionDays: Int

    init(_ settings: VaultSettings) {
        enabled = settings.captureEnabled
        ignoreConcealed = settings.ignoreConcealed
        excludedApps = settings.excludedApps
        historyLimit = settings.historyLimit
        retentionDays = settings.retentionDays
    }

    func validate() throws {
        var settings = VaultSettings()
        settings.captureEnabled = enabled
        settings.ignoreConcealed = ignoreConcealed
        settings.excludedApps = excludedApps
        settings.historyLimit = historyLimit
        settings.retentionDays = retentionDays
        _ = try settings.validated()
    }
}

public struct CaptureConfiguration: Codable, Equatable {
    public let publicKey: Data
    public let policy: CapturePolicy
    public let acknowledgedSequence: UInt64

    init?(document: VaultDocument) throws {
        guard let bytes = document.capturePrivateKey else { return nil }
        publicKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: bytes).publicKey.x963Representation
        policy = CapturePolicy(document.settings)
        acknowledgedSequence = document.lastImportedSequence ?? 0
    }

    func validate() throws {
        _ = try P256.KeyAgreement.PublicKey(x963Representation: publicKey)
        try policy.validate()
    }
}

public struct EncryptedCaptureInbox {
    public let directory: URL
    public static let maximumBytes = 64 * 1024 * 1024
    private static let maximumRecordBytes = 9 * 1024 * 1024
    private static let info = Data("ClipVault encrypted capture inbox v1".utf8)

    private struct Record: Codable {
        let sequence: UInt64
        let publicKey: Data
        let salt: Data
        let ciphertext: Data
    }

    struct Batch {
        let entries: [ClipboardEntry]
        let lastSequence: UInt64
    }

    private struct File {
        let url: URL
        let sequence: UInt64
        let size: Int
        let modified: Date
    }

    public init(directory: URL) { self.directory = directory }

    func enqueue(_ entry: ClipboardEntry, configuration: CaptureConfiguration, now: Date) throws {
        try entry.validate()
        try configuration.validate()
        let files = try records()
        let counterURL = directory.appendingPathComponent("sequence")
        let counter: UInt64
        if FileManager.default.fileExists(atPath: counterURL.path) {
            guard let size = try counterURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32 else { throw VaultError.invalidFormat }
            counter = try JSONDecoder().decode(UInt64.self, from: Data(contentsOf: counterURL))
        } else { counter = 0 }
        let previous = max(counter, max(configuration.acknowledgedSequence, files.last?.sequence ?? 0))
        guard previous < UInt64.max else { throw VaultError.inboxFull }
        let sequence = previous + 1
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let recipient = try P256.KeyAgreement.PublicKey(x963Representation: configuration.publicKey)
        let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Self.info + configuration.publicKey, outputByteCount: 32)
        let plaintext = try JSONEncoder().encode(entry)
        let ciphertext = try AES.GCM.seal(plaintext, using: key, authenticating: associatedData(sequence)).combined!
        let record = Record(sequence: sequence, publicKey: ephemeral.publicKey.x963Representation, salt: salt, ciphertext: ciphertext)
        let bytes = try JSONEncoder().encode(record)
        guard bytes.count <= Self.maximumRecordBytes else { throw VaultError.invalidFormat }
        let oldest = now.addingTimeInterval(-Double(configuration.policy.retentionDays) * 86400)
        let eligible = files.filter { $0.modified >= oldest }
        let retained = Array(eligible.suffix(max(0, configuration.policy.historyLimit - 1)))
        guard retained.reduce(0, { $0 + $1.size }) + bytes.count <= Self.maximumBytes else { throw VaultError.inboxFull }
        try PrivateFile.write(JSONEncoder().encode(sequence), to: counterURL)
        let url = directory.appendingPathComponent(String(format: "%020llu.capture", sequence))
        try PrivateFile.write(bytes, to: url)
        try FileManager.default.setAttributes([.modificationDate: entry.createdAt], ofItemAtPath: url.path)
        let retainedSequences = Set(retained.map(\.sequence))
        for file in files where !retainedSequences.contains(file.sequence) { try FileManager.default.removeItem(at: file.url) }

    }

    func read(after sequence: UInt64, privateKey bytes: Data) throws -> Batch {
        let privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: bytes)
        var entries: [ClipboardEntry] = []
        var last = sequence
        for file in try records() where file.sequence > sequence {
            guard file.size <= Self.maximumRecordBytes else { throw VaultError.invalidFormat }
            let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: file.url, options: .uncached))
            guard record.sequence == file.sequence, record.salt.count == 32 else { throw VaultError.invalidFormat }
            let peer = try P256.KeyAgreement.PublicKey(x963Representation: record.publicKey)
            let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
            let key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: record.salt, sharedInfo: Self.info + privateKey.publicKey.x963Representation, outputByteCount: 32)
            let box = try AES.GCM.SealedBox(combined: record.ciphertext)
            let plaintext = try AES.GCM.open(box, using: key, authenticating: associatedData(file.sequence))
            let entry = try JSONDecoder().decode(ClipboardEntry.self, from: plaintext)
            try entry.validate()
            entries.append(entry)
            last = file.sequence
        }
        return Batch(entries: entries, lastSequence: last)
    }

    func acknowledge(through sequence: UInt64) throws {
        for file in try records() where file.sequence <= sequence { try FileManager.default.removeItem(at: file.url) }
    }

    private func records() throws -> [File] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
            .filter { $0.pathExtension == "capture" }.map { url in
                guard let sequence = UInt64(url.deletingPathExtension().lastPathComponent), sequence > 0,
                      url.lastPathComponent == String(format: "%020llu.capture", sequence) else { throw VaultError.invalidFormat }
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                guard let size = values.fileSize, let modified = values.contentModificationDate else { throw VaultError.invalidFormat }
                return File(url: url, sequence: sequence, size: size, modified: modified)
            }.sorted { $0.sequence < $1.sequence }
    }

    private func associatedData(_ sequence: UInt64) -> Data {
        Self.info + Data(String(sequence).utf8)
    }
}
