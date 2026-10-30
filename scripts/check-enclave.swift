import Foundation
import CryptoKit
import LocalAuthentication
import Security

guard SecureEnclave.isAvailable else { fatalError("This Mac has no available Secure Enclave") }
var accessError: Unmanaged<CFError>?
guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .userPresence], &accessError) else { fatalError("Could not create access control") }
let context = LAContext()
context.interactionNotAllowed = true
let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access, authenticationContext: context)
let peer = P256.KeyAgreement.PrivateKey()
_ = try peer.sharedSecretFromKeyAgreement(with: enclave.publicKey)
let restored = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: enclave.dataRepresentation, authenticationContext: context)
do {
    _ = try restored.sharedSecretFromKeyAgreement(with: peer.publicKey)
    fatalError("Private key operation unexpectedly succeeded without user presence")
} catch {
    let failure = error as NSError
    precondition(failure.domain == LAError.errorDomain && failure.code == LAError.notInteractive.rawValue, "Expected user-interaction refusal, received \(failure.domain) \(failure.code)")
    print("PASS. Secure Enclave key creation, serialization, and reconstruction succeeded. Private operation without user presence was blocked.")
}
