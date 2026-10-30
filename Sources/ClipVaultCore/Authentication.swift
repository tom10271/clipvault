import Foundation
import Security
@preconcurrency import LocalAuthentication
import CryptoKit

@MainActor public protocol VaultKeyProvider: AnyObject {
    func unlock(allowCreation: Bool) async throws -> SymmetricKey
    func cancel()
}

@MainActor public final class EnclaveKeyProvider: VaultKeyProvider {
    private var context: LAContext?
    private let url: URL
    private struct Envelope: Codable {
        let enclave: Data
        let peerPublicKey: Data
        let salt: Data
    }
    public init(url: URL) { self.url = url }

    public func cancel() {
        context?.invalidate()
        context = nil
    }

    public func unlock(allowCreation: Bool) async throws -> SymmetricKey {
        guard SecureEnclave.isAvailable else { throw VaultError.enclaveUnavailable }
        let context = LAContext()
        self.context = context
        context.touchIDAuthenticationAllowableReuseDuration = 0
        context.localizedCancelTitle = "Keep locked"
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            throw policyError ?? VaultError.authenticationUnavailable as NSError
        }
        try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your encrypted clipboard history")
        guard self.context === context else { throw CancellationError() }
        if FileManager.default.fileExists(atPath: url.path) {
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8192 else { throw VaultError.invalidFormat }
            let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
            guard envelope.salt.count == 32 else { throw VaultError.invalidFormat }
            let secret: SharedSecret = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: envelope.enclave, authenticationContext: context)
                        let peer = try P256.KeyAgreement.PublicKey(x963Representation: envelope.peerPublicKey)
                        continuation.resume(returning: try privateKey.sharedSecretFromKeyAgreement(with: peer))
                    } catch { continuation.resume(throwing: error) }
                }
            }
            guard self.context === context else { throw CancellationError() }
            return derive(secret, salt: envelope.salt)
        }
        guard allowCreation else { throw VaultError.missingKey }
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .userPresence], &accessError) else {
            throw accessError?.takeRetainedValue() as Error? ?? VaultError.accessControl(errSecParam)
        }
        let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access, authenticationContext: context)
        let peer = P256.KeyAgreement.PrivateKey()
        let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let secret = try peer.sharedSecretFromKeyAgreement(with: enclave.publicKey)
        let envelope = Envelope(enclave: enclave.dataRepresentation, peerPublicKey: peer.publicKey.x963Representation, salt: salt)
        try PrivateFile.write(JSONEncoder().encode(envelope), to: url)
        return derive(secret, salt: salt)
    }

    private func derive(_ secret: SharedSecret, salt: Data) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data("ClipVault history encryption v1".utf8), outputByteCount: 32)
    }
}
