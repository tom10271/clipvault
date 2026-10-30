import Testing
import CryptoKit
import AppKit
@testable import ClipVaultCore

@Suite(.serialized) @MainActor struct SensitiveItemTests {
    let fixture = ClipVaultTests()

    func capture(clock: ClipVaultTests.Clock = .init()) async -> (ClipboardController, ClipVaultTests.Store, ClipVaultTests.Keys) {
        let result = fixture.make(clock: clock)
        await result.0.unlock()
        fixture.listen(result.0)
        fixture.write("synthetic-private-value")
        result.0.tick()
        return result
    }

    @Test func ordinaryAndLegacyItemsAreVisibleByDefault() async throws {
        let (model, _, _) = await capture()
        #expect(!model.entries[0].isSensitive)
        #expect(model.entries[0].name == nil)
        #expect(model.isValueVisible(model.entries[0]))
        let oldJSON = Data("{\"id\":\"\(UUID().uuidString)\",\"text\":\"old text\",\"createdAt\":100}".utf8)
        let old = try JSONDecoder().decode(ClipboardEntry.self, from: oldJSON)
        #expect(!old.isSensitive)
        #expect(old.name == nil)
    }

    @Test func savedSensitivityAndNameSurviveRestartLockAndTrash() async throws {
        let (model, store, keys) = await capture()
        let id = model.entries[0].id
        model.rename(id, name: "  Work API key  ")
        model.setSensitive(id, isSensitive: true)
        #expect(!model.isValueVisible(model.entries[0]))
        model.softDelete(id)
        model.lock()
        let restarted = ClipboardController(storage: store, keys: keys, inbox: EncryptedCaptureInbox(directory: fixture.directory.appendingPathComponent("inbox")), pasteboard: fixture.pasteboard)
        await restarted.unlock()
        #expect(restarted.entries[0].isSensitive)
        #expect(restarted.entries[0].name == "Work API key")
        #expect(restarted.entries[0].deletedAt != nil)
        restarted.restore(id)
        #expect(restarted.entries[0].deletedAt == nil)
        #expect(!restarted.isValueVisible(restarted.entries[0]))
        #expect(try store.load(key: keys.key).entries[0].name == "Work API key")
    }

    @Test func hiddenCopyDoesNotRevealOrChangeSavedSensitivity() async {
        let (model, _, _) = await capture()
        let id = model.entries[0].id
        model.rename(id, name: "Service credential")
        model.setSensitive(id, isSensitive: true)
        model.copy(id)
        #expect(fixture.pasteboard.string(forType: .string) == "synthetic-private-value")
        #expect(model.entries[0].isSensitive)
        #expect(!model.isValueVisible(model.entries[0]))
        #expect(model.matches(model.entries[0], search: "service"))
        #expect(!model.matches(model.entries[0], search: "synthetic-private-value"))
    }

    @Test func temporaryShowExpiresAndNeverChangesSavedSensitivity() async throws {
        let clock = ClipVaultTests.Clock()
        let (model, store, keys) = await capture(clock: clock)
        let id = model.entries[0].id
        model.setSensitive(id, isSensitive: true)
        model.revealValue(id)
        #expect(model.isValueVisible(model.entries[0]))
        #expect(try store.load(key: keys.key).entries[0].isSensitive)
        clock.seconds += 9
        #expect(model.isValueVisible(model.entries[0]))
        clock.seconds += 1
        #expect(!model.isValueVisible(model.entries[0]))
        model.tick()
        #expect(model.isUnlocked)
        #expect(model.entries[0].isSensitive)
    }

    @Test func closeHistoryAndLockClearTemporaryShow() async {
        let (model, _, _) = await capture()
        let id = model.entries[0].id
        model.setSensitive(id, isSensitive: true)
        model.revealValue(id)
        model.hideSensitivePreviews()
        #expect(!model.isValueVisible(model.entries[0]))
        model.revealValue(id)
        model.lock()
        #expect(model.entries.isEmpty)
        await model.unlock()
        #expect(!model.isValueVisible(model.entries[0]))
    }

    @Test func countdownUsesRevealDeadlineAndCopyDoesNotRestartIt() async {
        let clock = ClipVaultTests.Clock()
        let (model, _, _) = await capture(clock: clock)
        let id = model.entries[0].id
        #expect(model.revealSecondsRemaining(model.entries[0]) == 0)
        model.setSensitive(id, isSensitive: true)
        #expect(model.revealSecondsRemaining(model.entries[0]) == 0)
        model.revealValue(id)
        #expect(model.revealSecondsRemaining(model.entries[0]) == 10)
        clock.seconds += 0.2
        #expect(model.revealSecondsRemaining(model.entries[0]) == 10)
        clock.seconds += 0.9
        #expect(model.revealSecondsRemaining(model.entries[0]) == 9)
        model.copy(id)
        #expect(model.revealSecondsRemaining(model.entries[0]) == 9)
        clock.seconds += 8.9
        #expect(model.revealSecondsRemaining(model.entries[0]) == 0)
        #expect(!model.isValueVisible(model.entries[0]))
    }

    @Test func countdownExpiresWhenCapturePausedAndClearsOnCloseAndLock() async {
        let clock = ClipVaultTests.Clock()
        let (model, _, _) = await capture(clock: clock)
        let id = model.entries[0].id
        model.setSensitive(id, isSensitive: true)
        model.revealValue(id)
        model.toggleCapture()
        clock.seconds += 4
        model.tick()
        #expect(!model.isCapturing)
        #expect(model.revealSecondsRemaining(model.entries[0]) == 6)
        model.hideSensitivePreviews()
        #expect(model.revealSecondsRemaining(model.entries[0]) == 0)
        model.revealValue(id)
        let sensitive = model.entries[0]
        model.lock()
        #expect(model.revealSecondsRemaining(sensitive) == 0)
        await model.unlock()
        #expect(model.revealSecondsRemaining(model.entries[0]) == 0)
    }

    @Test func explicitAlwaysShowIsSaved() async {
        let (model, _, _) = await capture()
        let id = model.entries[0].id
        model.rename(id, name: "Named item")
        model.setSensitive(id, isSensitive: true)
        model.setSensitive(id, isSensitive: false)
        model.lock()
        await model.unlock()
        #expect(!model.entries[0].isSensitive)
        #expect(model.entries[0].name == "Named item")
        #expect(model.isValueVisible(model.entries[0]))
    }

    @Test func metadataStaysEncryptedAndOutOfPublicCaptureHeader() async throws {
        let (model, store, keys) = await capture()
        let id = model.entries[0].id
        model.rename(id, name: "Private label only inside ciphertext")
        model.setSensitive(id, isSensitive: true)
        let bytes = try Data(contentsOf: store.real.url)
        #expect(bytes.range(of: Data("Private label only inside ciphertext".utf8)) == nil)
        #expect(bytes.range(of: Data("synthetic-private-value".utf8)) == nil)
        let header = try JSONEncoder().encode(store.captureConfiguration())
        #expect(header.range(of: Data("Private label".utf8)) == nil)
        #expect(header.range(of: Data("isSensitive".utf8)) == nil)
        let persisted = try store.load(key: keys.key)
        #expect(persisted.entries[0].isSensitive)
        #expect(persisted.entries[0].name == "Private label only inside ciphertext")
    }

    @Test func failedAndInvalidMetadataChangesPreserveCommittedState() async throws {
        let (model, store, _) = await capture()
        let id = model.entries[0].id
        model.rename(id, name: "Original label")
        model.setSensitive(id, isSensitive: true)
        let original = try Data(contentsOf: store.real.url)
        store.failWrites = true
        model.rename(id, name: "Unsaved label")
        model.setSensitive(id, isSensitive: false)
        #expect(model.entries[0].name == "Original label")
        #expect(model.entries[0].isSensitive)
        #expect(try Data(contentsOf: store.real.url) == original)
        store.failWrites = false
        model.rename(id, name: String(repeating: "x", count: 121))
        #expect(model.entries[0].name == "Original label")
        #expect(try Data(contentsOf: store.real.url) == original)
        model.rename(id, name: "   ")
        #expect(model.entries[0].name == nil)
    }

    @Test func nameValidationAppliesAtStorageBoundary() async throws {
        let (_, store, keys) = await capture()
        let original = try Data(contentsOf: store.real.url)
        var document = try store.load(key: keys.key)
        document.entries[0].name = String(repeating: "x", count: 121)
        #expect(throws: (any Error).self) { try store.save(document, key: keys.key) }
        #expect(try Data(contentsOf: store.real.url) == original)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ClipboardEntry.self, from: Data("{\"id\":\"\(UUID().uuidString)\",\"text\":\"text\",\"createdAt\":100,\"name\":\"\(String(repeating: "x", count: 121))\"}".utf8)) }
    }

    @Test func queuedRecopyInheritsSensitiveNameAfterUnlock() async {
        let (model, _, _) = await capture()
        let id = model.entries[0].id
        model.rename(id, name: "Work token")
        model.setSensitive(id, isSensitive: true)
        fixture.write("ordinary intervening copy")
        model.tick()
        model.lock()
        fixture.write("synthetic-private-value")
        model.tick()
        await model.unlock()
        #expect(model.entries[0].name == "Work token")
        #expect(model.entries[0].isSensitive)
        #expect(!model.isValueVisible(model.entries[0]))
    }

    @Test func explicitSensitivityChoiceSurvivesNonconsecutiveRecopies() async {
        let (model, _, _) = await capture()
        let originalID = model.entries[0].id
        model.setSensitive(originalID, isSensitive: true)
        fixture.write("another value"); model.tick()
        fixture.write("synthetic-private-value"); model.tick()
        let repeatedID = model.entries[0].id
        #expect(repeatedID != originalID)
        model.revealValue(originalID)
        model.setSensitive(repeatedID, isSensitive: false)
        #expect(model.entries.filter { $0.text == "synthetic-private-value" }.allSatisfy { !$0.isSensitive })
        fixture.write("another value"); model.tick()
        fixture.write("synthetic-private-value"); model.tick()
        #expect(model.isValueVisible(model.entries[0]))
        model.setSensitive(repeatedID, isSensitive: true)
        #expect(model.entries.filter { $0.text == "synthetic-private-value" }.allSatisfy { $0.isSensitive && !model.isValueVisible($0) })
        fixture.write("another value"); model.tick()
        fixture.write("synthetic-private-value"); model.tick()
        #expect(model.entries[0].isSensitive)
        #expect(!model.isValueVisible(model.entries[0]))
        model.lock()
        await model.unlock()
        #expect(model.entries.filter { $0.text == "synthetic-private-value" }.allSatisfy { $0.isSensitive })
    }

    @Test func legacyPendingRecordWithoutMetadataImportsVisible() async throws {
        let (model, store, keys) = fixture.make()
        await model.unlock()
        fixture.listen(model)
        model.lock()
        let document = try store.load(key: keys.key)
        let configuration = try CaptureConfiguration(document: document)!
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let info = Data("ClipVault encrypted capture inbox v1".utf8)
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: configuration.publicKey))
        let encryptionKey = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: info + configuration.publicKey, outputByteCount: 32)
        let json = Data("{\"id\":\"\(UUID().uuidString)\",\"text\":\"legacy pending copy\",\"createdAt\":\(Date().timeIntervalSinceReferenceDate)}".utf8)
        let ciphertext = try AES.GCM.seal(json, using: encryptionKey, authenticating: info + Data("1".utf8)).combined!
        struct LegacyRecord: Encodable { let sequence: UInt64; let publicKey: Data; let salt: Data; let ciphertext: Data }
        let record = LegacyRecord(sequence: 1, publicKey: ephemeral.publicKey.x963Representation, salt: salt, ciphertext: ciphertext)
        let inbox = fixture.directory.appendingPathComponent("inbox")
        try PrivateFile.write(JSONEncoder().encode(record), to: inbox.appendingPathComponent("00000000000000000001.capture"))
        await model.unlock()
        #expect(model.entries[0].text == "legacy pending copy")
        #expect(!model.entries[0].isSensitive)
        #expect(model.entries[0].name == nil)
        #expect(model.isValueVisible(model.entries[0]))
    }
}
