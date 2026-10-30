import Testing
import CryptoKit
import AppKit
@testable import ClipVaultCore

@Suite(.serialized) @MainActor final class ClipVaultTests {
    final class Keys: VaultKeyProvider {
        let key = SymmetricKey(size: .bits256)
        var creation: [Bool] = []
        var failure = false
        var deferred: CheckedContinuation<SymmetricKey, Error>?
        var delay = false
        func unlock(allowCreation: Bool) async throws -> SymmetricKey {
            creation.append(allowCreation)
            if failure { throw VaultError.authenticationUnavailable }
            if delay { return try await withCheckedThrowingContinuation { deferred = $0 } }
            return key
        }
        func cancel() {}
    }
    final class Store: VaultStorage {
        let real: EncryptedVaultStore
        var failWrites = false
        var afterSave: (() -> Void)?
        init(_ url: URL) { real = EncryptedVaultStore(url: url) }
        var exists: Bool { real.exists }
        func load(key: SymmetricKey) throws -> VaultDocument { try real.load(key: key) }
        func captureConfiguration() throws -> CaptureConfiguration? { try real.captureConfiguration() }
        func save(_ document: VaultDocument, key: SymmetricKey) throws {
            if failWrites { throw CocoaError(.fileWriteOutOfSpace) }
            try real.save(document, key: key)
            afterSave?()
        }
    }
    final class Clock { var seconds: TimeInterval = 100; var date = Date() }
    let directory: URL
    let pasteboard: NSPasteboard
    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClipVault-tests-\(UUID().uuidString)")
        pasteboard = NSPasteboard(name: NSPasteboard.Name("ClipVault-tests-\(UUID().uuidString)"))
    }
    deinit {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: directory)
    }
    func make(clock: Clock = Clock()) -> (ClipboardController, Store, Keys) {
        let store = Store(directory.appendingPathComponent("history.vault"))
        let keys = Keys()
        let model = ClipboardController(storage: store, keys: keys, inbox: EncryptedCaptureInbox(directory: directory.appendingPathComponent("inbox")), pasteboard: pasteboard, uptime: { clock.seconds }, now: { clock.date })
        return (model, store, keys)
    }
    func write(_ text: String, marker: String? = nil) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if let marker { item.setData(Data(), forType: NSPasteboard.PasteboardType(marker)) }
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([item]))
    }
    func listen(_ model: ClipboardController) {
        var settings = model.settings
        settings.captureEnabled = true
        model.saveSettings(settings)
    }

    @Test func testEncryptionRoundTripAndPermissions() async throws {
        let (_, store, keys) = make()
        var document = VaultDocument()
        document.entries = [ClipboardEntry(text: "a-secret-never-written-plainly")]
        try store.save(document, key: keys.key)
        #expect(try store.load(key: keys.key) == document)
        let bytes = try Data(contentsOf: store.real.url)
        #expect(bytes.range(of: Data("a-secret-never-written-plainly".utf8)) == nil)
        let attrs = try FileManager.default.attributesOfItem(atPath: store.real.url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((dirAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }
    @Test func testWrongKeyAndTamperingRejected() async throws {
        let (_, store, keys) = make()
        try store.save(VaultDocument(), key: keys.key)
        #expect(throws: (any Error).self) { try store.load(key: SymmetricKey(size: .bits256)) }
        var bytes = try Data(contentsOf: store.real.url)
        bytes[bytes.count - 1] ^= 1
        try bytes.write(to: store.real.url)
        #expect(throws: (any Error).self) { try store.load(key: keys.key) }
    }
    @Test func testInvalidSavePreservesExistingSnapshot() async throws {
        let (_, store, keys) = make()
        let document = VaultDocument()
        try store.save(document, key: keys.key)
        let original = try Data(contentsOf: store.real.url)
        var invalid = document
        invalid.entries = [ClipboardEntry(text: String(repeating: "x", count: 1024 * 1024 + 1))]
        #expect(throws: (any Error).self) { try store.save(invalid, key: keys.key) }
        #expect(try Data(contentsOf: store.real.url) == original)
        #expect(try store.load(key: keys.key) == document)
    }
    @Test func testCaptureIsOptInAndSkipsExistingClipboard() async {
        write("already present")
        let (model, _, _) = make()
        await model.unlock()
        model.tick()
        #expect(model.entries.isEmpty)
        write("opted out")
        model.tick()
        #expect(model.entries.isEmpty)
        listen(model)
        model.tick()
        #expect(model.entries.isEmpty)
        write("new copy")
        model.tick()
        #expect(model.entries.map(\.text) == ["new copy"])
    }
    @Test func testPrivateAndExcludedContentSkipped() async {
        let (model, _, _) = make()
        await model.unlock()
        listen(model)
        write("password", marker: "org.nspasteboard.ConcealedType")
        model.tick()
        #expect(model.entries.isEmpty)
        var settings = model.settings
        settings.excludedApps = ["example.excluded"]
        model.saveSettings(settings)
        write("excluded")
        model.tick(frontmostBundleID: "example.excluded")
        #expect(model.entries.isEmpty)
        settings.ignoreConcealed = false
        model.saveSettings(settings)
        write("explicitly opted in", marker: "org.nspasteboard.ConcealedType")
        model.tick()
        #expect(model.entries.map(\.text) == ["explicitly opted in"])
    }
    @Test func testCaptureDoesNotExtendLockDeadlineAndLockedChangesImported() async {
        let clock = Clock()
        let (model, _, _) = make(clock: clock)
        await model.unlock()
        listen(model)
        clock.seconds += 59
        write("secret")
        model.tick()
        #expect(model.isUnlocked)
        clock.seconds += 2
        model.tick()
        #expect(!(model.isUnlocked))
        #expect(model.entries.isEmpty)
        write("copied while locked")
        model.tick()
        #expect(model.entries.isEmpty)
        #expect(model.isCapturing)
        await model.unlock()
        #expect(model.entries.map(\.text) == ["copied while locked", "secret"])
    }
    @Test func testSensitiveActionChecksDeadlineBeforeDelayedTimer() async {
        let clock = Clock()
        let (model, _, _) = make(clock: clock)
        await model.unlock()
        listen(model)
        write("secret")
        model.tick()
        let id = model.entries[0].id
        write("newer")
        clock.seconds += 61
        model.copy(id)
        #expect(!(model.isUnlocked))
        #expect(pasteboard.string(forType: .string) == "newer")
    }
    @Test func testSlowSaveCannotReopenExpiredSession() async {
        let clock = Clock()
        let (model, store, _) = make(clock: clock)
        await model.unlock()
        listen(model)
        write("secret")
        store.afterSave = { clock.seconds += 61 }
        model.tick()
        #expect(!model.isUnlocked)
        #expect(model.entries.isEmpty)
    }
    @Test func testDeleteRestoreAndPermanentDeleteSurviveRestart() async throws {
        let (model, store, keys) = make()
        await model.unlock()
        listen(model)
        write("delete me")
        model.tick()
        let id = model.entries[0].id
        model.softDelete(id)
        #expect(try store.load(key: keys.key).entries[0].deletedAt != nil)
        #expect(pasteboard.string(forType: .string) == nil)
        model.restore(id)
        #expect(try store.load(key: keys.key).entries[0].deletedAt == nil)
        model.permanentlyDelete(id)
        model.lock()
        await model.unlock()
        #expect(model.entries.isEmpty)
        #expect(try store.load(key: keys.key).entries.isEmpty)
    }
    @Test func testFailedWritePreservesPublishedAndPersistedHistory() async throws {
        let (model, store, keys) = make()
        await model.unlock()
        listen(model)
        write("keep me")
        model.tick()
        let original = try Data(contentsOf: store.real.url)
        store.failWrites = true
        model.permanentlyDelete(model.entries[0].id)
        #expect(model.entries.map(\.text) == ["keep me"])
        #expect(try Data(contentsOf: store.real.url) == original)
        #expect(try store.load(key: keys.key).entries.map(\.text) == ["keep me"])
        #expect(model.message != nil)
        write("unsaved")
        model.tick()
        #expect(!(model.isCapturing))
        #expect(model.entries.map(\.text) == ["keep me"])
    }
    @Test func testConditionalClipboardExpiryKeepsNewerContent() async {
        let clock = Clock()
        let (model, _, _) = make(clock: clock)
        await model.unlock()
        listen(model)
        write("copy me")
        model.tick()
        model.copy(model.entries[0].id)
        clock.seconds += 31
        model.tick()
        #expect(pasteboard.string(forType: .string) == nil)
        model.copy(model.entries[0].id)
        write("newer unrelated content")
        clock.seconds += 31
        model.tick()
        #expect(pasteboard.string(forType: .string) == "newer unrelated content")
    }
    @Test func testLockClearsOnlyOwnedClipboard() async {
        let (model, _, _) = make()
        await model.unlock()
        listen(model)
        write("secret")
        model.tick()
        let id = model.entries[0].id
        model.copy(id)
        model.lock()
        #expect(pasteboard.string(forType: .string) == nil)
        await model.unlock()
        model.copy(id)
        write("not owned")
        model.lock()
        #expect(pasteboard.string(forType: .string) == "not owned")
    }
    @Test func testLimitsIncludeTrashAndRetention() async {
        let clock = Clock()
        let (model, _, _) = make(clock: clock)
        await model.unlock()
        var settings = model.settings
        settings.captureEnabled = true
        settings.historyLimit = 2
        settings.retentionDays = 1
        model.saveSettings(settings)
        for text in ["one", "two", "three"] { write(text); model.tick() }
        #expect(model.entries.map(\.text) == ["three", "two"])
        model.softDelete(model.entries[0].id)
        clock.date += 86401
        write("four")
        model.tick()
        #expect(model.entries.map(\.text) == ["four"])
    }
    @Test func testInvalidSettingsAreRejectedWithoutChangingVault() async {
        let (model, _, _) = make()
        await model.unlock()
        let original = model.settings
        var invalid = original
        invalid.autoLockSeconds = .infinity
        model.saveSettings(invalid)
        #expect(model.settings == original)
        #expect(model.message != nil)
    }
    @Test func testAuthenticationFailureLeavesVaultLocked() async {
        let (model, store, keys) = make()
        keys.failure = true
        await model.unlock()
        #expect(!(model.isUnlocked))
        #expect(!(store.exists))
        #expect(model.message != nil)
    }
    @Test func testLockDuringAuthenticationCannotReopenVault() async {
        let (model, store, keys) = make()
        keys.delay = true
        let unlock = Task { await model.unlock() }
        await Task.yield()
        #expect(model.isUnlocking)
        model.lock()
        keys.deferred?.resume(returning: keys.key)
        await unlock.value
        #expect(!(model.isUnlocked))
        #expect(!(store.exists))
    }
    @Test func testExistingVaultNeverRequestsReplacementKey() async {
        let (model, _, keys) = make()
        await model.unlock()
        model.lock()
        await model.unlock()
        #expect(keys.creation == [true, false])
    }
    @Test func testCorruptVaultNeverGetsOverwritten() async throws {
        let (model, store, keys) = make()
        try store.save(VaultDocument(), key: keys.key)
        let corrupt = Data("invalid vault".utf8)
        try corrupt.write(to: store.real.url)
        await model.unlock()
        #expect(!(model.isUnlocked))
        #expect(try Data(contentsOf: store.real.url) == corrupt)
        #expect(model.message != nil)
    }
    @Test func testManualLockKeepsPublicOnlyCaptureAndImportsAfterUnlock() async throws {
        let (model, store, keys) = make()
        await model.unlock()
        listen(model)
        model.lock()
        let authentications = keys.creation.count
        #expect(model.isCapturing)
        write("captured-with-history-locked")
        model.tick()
        #expect(!model.isUnlocked)
        #expect(model.entries.isEmpty)
        #expect(keys.creation.count == authentications)
        let files = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("inbox"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "capture" }
        #expect(files.count == 1)
        let ciphertext = try Data(contentsOf: files[0])
        #expect(ciphertext.range(of: Data("captured-with-history-locked".utf8)) == nil)
        #expect(ciphertext.range(of: keys.key.withUnsafeBytes { Data($0) }) == nil)
        let document = try store.load(key: keys.key)
        #expect(ciphertext.range(of: document.capturePrivateKey!) == nil)
        #expect(document.entries.isEmpty)
        await model.unlock()
        #expect(model.entries.map(\.text) == ["captured-with-history-locked"])
    }
    @Test func testRestartListensBeforeAnyUnlock() async {
        let (first, store, keys) = make()
        await first.unlock()
        listen(first)
        first.lock()
        let authentications = keys.creation.count
        let restarted = ClipboardController(storage: store, keys: keys, inbox: EncryptedCaptureInbox(directory: directory.appendingPathComponent("inbox")), pasteboard: pasteboard)
        #expect(restarted.isCapturing)
        #expect(!restarted.isUnlocked)
        write("copied-after-restart-before-unlock")
        restarted.tick()
        #expect(restarted.entries.isEmpty)
        #expect(keys.creation.count == authentications)
        await restarted.unlock()
        #expect(restarted.entries.map(\.text) == ["copied-after-restart-before-unlock"])
    }
    @Test func testCaptureContinuesDuringAndAfterCanceledAuthentication() async {
        let (model, _, keys) = make()
        await model.unlock()
        listen(model)
        model.lock()
        keys.delay = true
        let opening = Task { await model.unlock() }
        await Task.yield()
        #expect(model.isUnlocking)
        write("during-authentication")
        model.tick()
        model.lock()
        keys.deferred?.resume(returning: keys.key)
        await opening.value
        #expect(model.entries.isEmpty)
        #expect(model.isCapturing)
        write("after-cancellation")
        model.tick()
        keys.delay = false
        await model.unlock()
        #expect(model.entries.map(\.text) == ["after-cancellation", "during-authentication"])
    }
    @Test func testLockedCaptureHonorsExclusionsAndExplicitPause() async {
        let (model, _, _) = make()
        await model.unlock()
        var settings = model.settings
        settings.captureEnabled = true
        settings.excludedApps = ["example.private"]
        model.saveSettings(settings)
        model.lock()
        write("private-marker", marker: "org.nspasteboard.ConcealedType")
        model.tick()
        write("private-app")
        model.tick(frontmostBundleID: "example.private")
        write("ordinary")
        model.tick(frontmostBundleID: "example.allowed")
        await model.unlock()
        #expect(model.entries.map(\.text) == ["ordinary"])
        settings.captureEnabled = false
        model.saveSettings(settings)
        model.lock()
        #expect(!model.isCapturing)
        write("paused")
        model.tick()
        await model.unlock()
        #expect(model.entries.map(\.text) == ["ordinary"])
    }
    @Test func testInboxWrongKeyAndTamperingRejectedWithoutLosingVault() async throws {
        let (model, store, keys) = make()
        await model.unlock()
        listen(model)
        model.lock()
        write("encrypted-pending")
        model.tick()
        let inbox = EncryptedCaptureInbox(directory: directory.appendingPathComponent("inbox"))
        #expect(throws: (any Error).self) { try inbox.read(after: 0, privateKey: P256.KeyAgreement.PrivateKey().rawRepresentation) }
        let url = try FileManager.default.contentsOfDirectory(at: inbox.directory, includingPropertiesForKeys: nil).first { $0.pathExtension == "capture" }!
        let originalVault = try Data(contentsOf: store.real.url)
        var bytes = try Data(contentsOf: url)
        bytes[bytes.count - 1] ^= 1
        try bytes.write(to: url)
        await model.unlock()
        #expect(!model.isUnlocked)
        #expect(model.message != nil)
        #expect(try Data(contentsOf: store.real.url) == originalVault)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try store.load(key: keys.key).entries.isEmpty)
    }
    @Test func testFailedImportRetainsEncryptedPendingForRetry() async throws {
        let (model, store, keys) = make()
        await model.unlock()
        listen(model)
        model.lock()
        write("pending-until-storage-recovers")
        model.tick()
        let before = try Data(contentsOf: store.real.url)
        store.failWrites = true
        await model.unlock()
        #expect(!model.isUnlocked)
        #expect(try Data(contentsOf: store.real.url) == before)
        #expect(try store.load(key: keys.key).entries.isEmpty)
        store.failWrites = false
        await model.unlock()
        #expect(model.entries.map(\.text) == ["pending-until-storage-recovers"])
    }
    @Test func testImportWatermarkPreventsReplayAfterCrashAndHardDelete() async throws {
        let (model, store, keys) = make()
        await model.unlock()
        listen(model)
        model.lock()
        write("must-not-resurrect")
        model.tick()
        let inbox = EncryptedCaptureInbox(directory: directory.appendingPathComponent("inbox"))
        let recordURL = try FileManager.default.contentsOfDirectory(at: inbox.directory, includingPropertiesForKeys: nil).first { $0.pathExtension == "capture" }!
        let recordBytes = try Data(contentsOf: recordURL)
        var committed = try store.load(key: keys.key)
        let batch = try inbox.read(after: 0, privateKey: committed.capturePrivateKey!)
        committed.entries = batch.entries
        committed.lastImportedSequence = batch.lastSequence
        try store.save(committed, key: keys.key)
        await model.unlock()
        #expect(model.entries.count == 1)
        model.permanentlyDelete(model.entries[0].id)
        #expect(model.entries.isEmpty)
        try recordBytes.write(to: recordURL)
        model.lock()
        await model.unlock()
        #expect(model.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: recordURL.path))
        #expect(try store.load(key: keys.key).lastImportedSequence == batch.lastSequence)
    }
    @Test func testLockedInboxCountAndRetentionLimits() async {
        let clock = Clock()
        let (model, _, _) = make(clock: clock)
        await model.unlock()
        var settings = model.settings
        settings.captureEnabled = true
        settings.historyLimit = 2
        settings.retentionDays = 1
        model.saveSettings(settings)
        model.lock()
        for text in ["one", "two", "three"] { write(text); model.tick() }
        await model.unlock()
        #expect(model.entries.map(\.text) == ["three", "two"])
        model.lock()
        write("old-pending")
        model.tick()
        clock.date += 86401
        write("new-pending")
        model.tick()
        await model.unlock()
        #expect(model.entries.map(\.text) == ["new-pending"])
    }
    @Test func testLegacyVaultMigratesWithoutChangingHistoryKey() async throws {
        let (model, store, keys) = make()
        var legacy = VaultDocument()
        legacy.settings.captureEnabled = true
        legacy.entries = [ClipboardEntry(text: "legacy-history")]
        let header = Data("CLIPVAULT1".utf8)
        let ciphertext = try AES.GCM.seal(JSONEncoder().encode(legacy), using: keys.key, authenticating: header).combined!
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (header + ciphertext).write(to: store.real.url)
        #expect(try store.captureConfiguration() == nil)
        await model.unlock()
        #expect(model.entries.map(\.text) == ["legacy-history"])
        #expect(try Data(contentsOf: store.real.url).starts(with: Data("CLIPVAULT2".utf8)))
        #expect(try store.load(key: keys.key).capturePrivateKey != nil)
        model.lock()
        write("post-migration-copy")
        model.tick()
        await model.unlock()
        #expect(model.entries.map(\.text) == ["post-migration-copy", "legacy-history"])
        #expect(keys.creation.allSatisfy { !$0 })
    }
    @Test func testInboxRejectsNoncanonicalSequenceFilename() async throws {
        let (model, _, _) = make()
        await model.unlock()
        listen(model)
        model.lock()
        write("one")
        model.tick()
        let inbox = EncryptedCaptureInbox(directory: directory.appendingPathComponent("inbox"))
        let canonical = inbox.directory.appendingPathComponent("00000000000000000001.capture")
        try FileManager.default.copyItem(at: canonical, to: inbox.directory.appendingPathComponent("1.capture"))
        await model.unlock()
        #expect(!model.isUnlocked)
        #expect(model.message != nil)
    }

    @Test func testSerializedByteRetentionKeepsNewestWholeEntries() throws {
        var document = VaultDocument()
        document.entries = [ClipboardEntry(text: "newest"), ClipboardEntry(text: String(repeating: "\u{1}", count: 200)), ClipboardEntry(text: "oldest")]
        var one = document
        one.entries = Array(document.entries.prefix(1))
        let budget = try JSONEncoder().encode(one).count
        try document.prune(now: Date(), maximumSerializedBytes: budget)
        #expect(document.entries.map(\.text) == ["newest"])
        #expect(try JSONEncoder().encode(document).count <= budget)
    }
    @Test func testLargePendingImportTrimsOldestInsteadOfBlockingUnlock() async throws {
        let (model, store, keys) = make()
        var document = VaultDocument()
        document.settings.captureEnabled = true
        document.capturePrivateKey = P256.KeyAgreement.PrivateKey().rawRepresentation
        let escaped = String(repeating: "\u{1}", count: 700_000)
        document.entries = (0..<8).map { ClipboardEntry(text: "old-\($0)-" + escaped) }
        try store.save(document, key: keys.key)
        let inbox = EncryptedCaptureInbox(directory: directory.appendingPathComponent("inbox"))
        let configuration = try CaptureConfiguration(document: document)!
        for i in 0..<8 { try inbox.enqueue(ClipboardEntry(text: "pending-\(i)-" + escaped), configuration: configuration, now: Date()) }
        await model.unlock()
        #expect(model.isUnlocked)
        #expect(model.entries.count < 16)
        #expect(model.entries.filter { $0.text.hasPrefix("pending-") }.count == 8)
        #expect(try JSONEncoder().encode(store.load(key: keys.key)).count <= EncryptedVaultStore.maximumPlaintextBytes)
    }
    @Test func testFailedInboxWriteDoesNotPrunePreviousPendingEntry() async throws {
        let (model, store, keys) = make()
        await model.unlock()
        var settings = model.settings
        settings.captureEnabled = true
        settings.historyLimit = 1
        model.saveSettings(settings)
        model.lock()
        write("first-pending")
        model.tick()
        let inbox = EncryptedCaptureInbox(directory: directory.appendingPathComponent("inbox"))
        let counter = inbox.directory.appendingPathComponent("sequence")
        let record = inbox.directory.appendingPathComponent("00000000000000000001.capture")
        let original = try Data(contentsOf: record)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: counter.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: counter.path) }
        write("cannot-be-written")
        model.tick()
        #expect(!model.isCapturing)
        let document = try store.load(key: keys.key)
        let batch = try inbox.read(after: 0, privateKey: document.capturePrivateKey!)
        #expect(batch.entries.map(\.text) == ["first-pending"])
        #expect(try Data(contentsOf: record) == original)
    }

    @Test func testInboxByteCeilingRejectsNewCopyWithoutDroppingExistingCopies() throws {
        var document = VaultDocument()
        document.capturePrivateKey = P256.KeyAgreement.PrivateKey().rawRepresentation
        document.settings.captureEnabled = true
        document.settings.historyLimit = 5000
        let configuration = try CaptureConfiguration(document: document)!
        let inbox = EncryptedCaptureInbox(directory: directory.appendingPathComponent("inbox"))
        let text = String(repeating: "x", count: 1024 * 1024)
        var accepted = 0
        var reachedLimit = false
        for i in 0..<60 {
            do {
                try inbox.enqueue(ClipboardEntry(text: String(i) + text.dropFirst(3)), configuration: configuration, now: Date())
                accepted += 1
            } catch VaultError.inboxFull { reachedLimit = true; break }
        }
        #expect(reachedLimit)
        let files = try FileManager.default.contentsOfDirectory(at: inbox.directory, includingPropertiesForKeys: [.fileSizeKey]).filter { $0.pathExtension == "capture" }
        #expect(files.count == accepted)
        let total = try files.reduce(0) { try $0 + $1.resourceValues(forKeys: [.fileSizeKey]).fileSize! }
        #expect(total <= EncryptedCaptureInbox.maximumBytes)
        #expect(try inbox.read(after: 0, privateKey: document.capturePrivateKey!).entries.count == accepted)
    }

}
