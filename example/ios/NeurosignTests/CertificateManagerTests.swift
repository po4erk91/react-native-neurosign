import XCTest
@testable import Neurosign

/// Tests certificate generation logic without Keychain access.
/// Uses TestSigningHelper to create ephemeral keys (no entitlements needed).
final class CertificateManagerTests: XCTestCase {

    // MARK: - Ephemeral identity generation (RSA)

    func test_generateEphemeralIdentity_RSA() throws {
        let identity = try TestSigningHelper.generateRSAIdentity()

        XCTAssertFalse(identity.certificateData.isEmpty)
        XCTAssertFalse(identity.certificateChain.isEmpty)

        // Certificate DER should start with SEQUENCE tag (0x30)
        XCTAssertEqual(identity.certificateData[0], 0x30)
    }

    // MARK: - Ephemeral identity generation (EC)

    func test_generateEphemeralIdentity_EC() throws {
        let identity = try TestSigningHelper.generateECIdentity()

        XCTAssertFalse(identity.certificateData.isEmpty)
        XCTAssertFalse(identity.certificateChain.isEmpty)
        XCTAssertEqual(identity.certificateData[0], 0x30)
    }

    // MARK: - Certificate DER structure

    func test_buildSelfSignedCertificateDER_RSA_isValidCert() throws {
        let keyParams: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var error: Unmanaged<CFError>?
        let privateKey = SecKeyCreateRandomKey(keyParams as CFDictionary, &error)!
        if error != nil { _ = error!.takeRetainedValue() }
        let publicKey = SecKeyCopyPublicKey(privateKey)!

        let now = Date()
        let expiry = Calendar.current.date(byAdding: .day, value: 1, to: now)!

        let certData = try CertificateManager.buildSelfSignedCertificateDER(
            privateKey: privateKey,
            publicKey: publicKey,
            commonName: "Test DER RSA",
            organization: "TestOrg",
            country: "US",
            notBefore: now,
            notAfter: expiry,
            isEC: false
        )

        // Should be parseable as SecCertificate
        let cert = SecCertificateCreateWithData(nil, certData as CFData)
        XCTAssertNotNil(cert, "DER data should create a valid SecCertificate")

        // Subject summary should contain the CN
        if let cert = cert {
            let summary = SecCertificateCopySubjectSummary(cert) as String?
            XCTAssertEqual(summary, "Test DER RSA")
        }
    }

    func test_buildSelfSignedCertificateDER_EC_isValidCert() throws {
        let keyParams: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var error: Unmanaged<CFError>?
        let privateKey = SecKeyCreateRandomKey(keyParams as CFDictionary, &error)!
        if error != nil { _ = error!.takeRetainedValue() }
        let publicKey = SecKeyCopyPublicKey(privateKey)!

        let now = Date()
        let expiry = Calendar.current.date(byAdding: .day, value: 1, to: now)!

        let certData = try CertificateManager.buildSelfSignedCertificateDER(
            privateKey: privateKey,
            publicKey: publicKey,
            commonName: "Test DER EC",
            organization: "",
            country: "",
            notBefore: now,
            notAfter: expiry,
            isEC: true
        )

        let cert = SecCertificateCreateWithData(nil, certData as CFData)
        XCTAssertNotNil(cert, "EC DER data should create a valid SecCertificate")
    }

}
