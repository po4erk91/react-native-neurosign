import XCTest
@testable import Neurosign

final class CertificateManagerTests: XCTestCase {

    private var testAlias: String!

    override func setUp() {
        super.setUp()
        testAlias = "test_cert_\(UUID().uuidString.prefix(8))"
    }

    override func tearDown() {
        _ = try? CertificateManager.deleteCertificate(alias: testAlias)
        super.tearDown()
    }

    // MARK: - generateSelfSigned

    func test_generateSelfSigned_RSA() throws {
        let info = try CertificateManager.generateSelfSigned(
            commonName: "Test RSA Cert",
            organization: "TestOrg",
            country: "US",
            validityDays: 1,
            alias: testAlias,
            keyAlgorithm: "RSA"
        )

        XCTAssertEqual(info.alias, testAlias)
        XCTAssertFalse(info.subject.isEmpty)
        XCTAssertFalse(info.serialNumber.isEmpty)
    }

    func test_generateSelfSigned_EC() throws {
        let info = try CertificateManager.generateSelfSigned(
            commonName: "Test EC Cert",
            organization: "TestOrg",
            country: "US",
            validityDays: 1,
            alias: testAlias,
            keyAlgorithm: "EC"
        )

        XCTAssertEqual(info.alias, testAlias)
        XCTAssertFalse(info.subject.isEmpty)
    }

    // MARK: - getSigningIdentity

    func test_getSigningIdentity_afterGenerate() throws {
        _ = try CertificateManager.generateSelfSigned(
            commonName: "Test Identity",
            organization: "",
            country: "",
            validityDays: 1,
            alias: testAlias
        )

        let identity = try CertificateManager.getSigningIdentity(alias: testAlias)
        XCTAssertFalse(identity.certificateChain.isEmpty)
        XCTAssertFalse(identity.certificateData.isEmpty)
    }

    // MARK: - listCertificates

    func test_listCertificates_includesGenerated() throws {
        _ = try CertificateManager.generateSelfSigned(
            commonName: "Test List",
            organization: "",
            country: "",
            validityDays: 1,
            alias: testAlias
        )

        let certs = CertificateManager.listCertificates()
        let found = certs.contains { $0.alias == testAlias }
        XCTAssertTrue(found, "Generated cert should appear in list")
    }

    // MARK: - deleteCertificate

    func test_deleteCertificate_removesFromKeychain() throws {
        _ = try CertificateManager.generateSelfSigned(
            commonName: "Test Delete",
            organization: "",
            country: "",
            validityDays: 1,
            alias: testAlias
        )

        let deleted = try CertificateManager.deleteCertificate(alias: testAlias)
        XCTAssertTrue(deleted)

        // After deletion, getSigningIdentity should throw
        XCTAssertThrowsError(try CertificateManager.getSigningIdentity(alias: testAlias))
    }
}
