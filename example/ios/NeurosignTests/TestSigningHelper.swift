import Foundation
import Security
@testable import Neurosign

/// Creates ephemeral SigningIdentity instances for unit tests
/// without requiring Keychain access (CODE_SIGNING_ALLOWED=NO compatible).
enum TestSigningHelper {

    static func generateRSAIdentity() throws -> CertificateManager.SigningIdentity {
        return try generateIdentity(keyType: kSecAttrKeyTypeRSA, keySize: 2048, isEC: false)
    }

    static func generateECIdentity() throws -> CertificateManager.SigningIdentity {
        return try generateIdentity(keyType: kSecAttrKeyTypeECSECPrimeRandom, keySize: 256, isEC: true)
    }

    private static func generateIdentity(
        keyType: CFString,
        keySize: Int,
        isEC: Bool
    ) throws -> CertificateManager.SigningIdentity {
        // Create ephemeral key pair (NOT stored in Keychain)
        let keyParams: [String: Any] = [
            kSecAttrKeyType as String: keyType,
            kSecAttrKeySizeInBits as String: keySize,
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyParams as CFDictionary, &error) else {
            throw error?.takeRetainedValue() ?? NSError(domain: "TestSigningHelper", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create ephemeral key pair"
            ])
        }
        if error != nil { _ = error!.takeRetainedValue() }

        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw NSError(domain: "TestSigningHelper", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to extract public key"
            ])
        }

        let now = Date()
        let expiry = Calendar.current.date(byAdding: .day, value: 1, to: now)!

        let certData = try CertificateManager.buildSelfSignedCertificateDER(
            privateKey: privateKey,
            publicKey: publicKey,
            commonName: "Test \(isEC ? "EC" : "RSA")",
            organization: "Test",
            country: "US",
            notBefore: now,
            notAfter: expiry,
            isEC: isEC
        )

        guard let certificate = SecCertificateCreateWithData(nil, certData as CFData) else {
            throw NSError(domain: "TestSigningHelper", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create SecCertificate from DER"
            ])
        }

        return CertificateManager.SigningIdentity(
            privateKey: privateKey,
            certificate: certificate,
            certificateChain: [certificate],
            certificateData: certData
        )
    }
}
