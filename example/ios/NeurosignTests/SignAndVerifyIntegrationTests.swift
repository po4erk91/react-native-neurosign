import XCTest
@testable import Neurosign

final class SignAndVerifyIntegrationTests: XCTestCase {

    private var testAlias: String!
    private var tempFiles: [URL] = []

    override func setUp() {
        super.setUp()
        testAlias = "test_sign_\(UUID().uuidString.prefix(8))"
        tempFiles = []
    }

    override func tearDown() {
        _ = try? CertificateManager.deleteCertificate(alias: testAlias)
        tempFiles.forEach { TestPdfBuilder.cleanup($0) }
        super.tearDown()
    }

    private func addTemp(_ url: URL) -> URL {
        tempFiles.append(url)
        return url
    }

    // MARK: - Sign + Verify Roundtrip

    func test_signAndVerify_selfSignedRSA() throws {
        _ = try CertificateManager.generateSelfSigned(
            commonName: "Test RSA",
            organization: "Test",
            country: "US",
            validityDays: 1,
            alias: testAlias,
            keyAlgorithm: "RSA"
        )
        let identity = try CertificateManager.getSigningIdentity(alias: testAlias)

        let pdfData = TestPdfBuilder.minimalPdf()
        let inputUrl = addTemp(TestPdfBuilder.writeTempFile(pdfData, name: "input.pdf"))
        let outputUrl = addTemp(TestPdfBuilder.writeTempFile(Data(), name: "signed.pdf"))

        try PdfSigner.signPdf(
            pdfUrl: inputUrl,
            identity: identity,
            reason: "Test",
            location: "Test",
            contactInfo: "test@test.com",
            outputUrl: outputUrl
        )

        let signatures = try PdfSigner.verifySignatures(pdfUrl: outputUrl)
        XCTAssertEqual(signatures.count, 1)
        XCTAssertTrue(signatures[0].valid)
        XCTAssertEqual(signatures[0].reason, "Test")
    }

    func test_signAndVerify_selfSignedEC() throws {
        _ = try CertificateManager.generateSelfSigned(
            commonName: "Test EC",
            organization: "Test",
            country: "US",
            validityDays: 1,
            alias: testAlias,
            keyAlgorithm: "EC"
        )
        let identity = try CertificateManager.getSigningIdentity(alias: testAlias)

        let pdfData = TestPdfBuilder.minimalPdf()
        let inputUrl = addTemp(TestPdfBuilder.writeTempFile(pdfData, name: "input_ec.pdf"))
        let outputUrl = addTemp(TestPdfBuilder.writeTempFile(Data(), name: "signed_ec.pdf"))

        try PdfSigner.signPdf(
            pdfUrl: inputUrl,
            identity: identity,
            reason: "EC Test",
            location: "Test",
            contactInfo: "test@test.com",
            outputUrl: outputUrl
        )

        let signatures = try PdfSigner.verifySignatures(pdfUrl: outputUrl)
        XCTAssertEqual(signatures.count, 1)
        XCTAssertTrue(signatures[0].valid)
    }

    func test_signAndVerify_tamperedPdf() throws {
        _ = try CertificateManager.generateSelfSigned(
            commonName: "Test Tamper",
            organization: "",
            country: "",
            validityDays: 1,
            alias: testAlias
        )
        let identity = try CertificateManager.getSigningIdentity(alias: testAlias)

        let pdfData = TestPdfBuilder.minimalPdf()
        let inputUrl = addTemp(TestPdfBuilder.writeTempFile(pdfData, name: "input_tamper.pdf"))
        let outputUrl = addTemp(TestPdfBuilder.writeTempFile(Data(), name: "signed_tamper.pdf"))

        try PdfSigner.signPdf(
            pdfUrl: inputUrl,
            identity: identity,
            reason: "Tamper test",
            location: "",
            contactInfo: "",
            outputUrl: outputUrl
        )

        // Tamper with the signed PDF — flip a byte near the start (inside hashed region)
        var tampered = try Data(contentsOf: outputUrl)
        if tampered.count > 20 {
            tampered[10] = tampered[10] ^ 0xFF
        }
        try tampered.write(to: outputUrl)

        let signatures = try PdfSigner.verifySignatures(pdfUrl: outputUrl)
        XCTAssertEqual(signatures.count, 1)
        XCTAssertFalse(signatures[0].valid)
    }

    func test_byteRange_coversAngleBrackets() throws {
        _ = try CertificateManager.generateSelfSigned(
            commonName: "Test ByteRange",
            organization: "",
            country: "",
            validityDays: 1,
            alias: testAlias
        )
        let identity = try CertificateManager.getSigningIdentity(alias: testAlias)

        let pdfData = TestPdfBuilder.minimalPdf()
        let inputUrl = addTemp(TestPdfBuilder.writeTempFile(pdfData, name: "input_br.pdf"))
        let outputUrl = addTemp(TestPdfBuilder.writeTempFile(Data(), name: "signed_br.pdf"))

        try PdfSigner.signPdf(
            pdfUrl: inputUrl,
            identity: identity,
            reason: "BR test",
            location: "",
            contactInfo: "",
            outputUrl: outputUrl
        )

        let signedData = try Data(contentsOf: outputUrl)
        let signedText = String(data: signedData, encoding: .isoLatin1)!

        // Find the ByteRange in the signed PDF
        let sigs = PdfSigner.findSignatureDictionaries(in: signedText)
        XCTAssertEqual(sigs.count, 1)

        guard let br = sigs[0].byteRange else {
            XCTFail("ByteRange not found in signed PDF")
            return
        }

        // The gap starts at br.1 (gapStart) and ends at br.2 (gapEnd)
        // Per PDF spec: the gap must cover <hex_digits> including angle brackets
        let gapStart = br.1
        let gapEnd = br.2

        XCTAssertTrue(gapStart < signedData.count)
        XCTAssertTrue(gapEnd <= signedData.count)

        // First byte of gap should be '<', last byte before gapEnd should be '>'
        XCTAssertEqual(signedData[gapStart], UInt8(ascii: "<"), "Gap should start with '<'")
        XCTAssertEqual(signedData[gapEnd - 1], UInt8(ascii: ">"), "Gap should end with '>'")
    }

    func test_signTwice_createsUniqueFieldNames() throws {
        _ = try CertificateManager.generateSelfSigned(
            commonName: "Test Double",
            organization: "",
            country: "",
            validityDays: 1,
            alias: testAlias
        )
        let identity = try CertificateManager.getSigningIdentity(alias: testAlias)

        let pdfData = TestPdfBuilder.minimalPdf()
        let inputUrl = addTemp(TestPdfBuilder.writeTempFile(pdfData, name: "input_double.pdf"))
        let firstUrl = addTemp(TestPdfBuilder.writeTempFile(Data(), name: "first.pdf"))
        let secondUrl = addTemp(TestPdfBuilder.writeTempFile(Data(), name: "second.pdf"))

        // First signature
        try PdfSigner.signPdf(
            pdfUrl: inputUrl, identity: identity,
            reason: "First", location: "", contactInfo: "",
            outputUrl: firstUrl
        )

        // Second signature on top of the first
        try PdfSigner.signPdf(
            pdfUrl: firstUrl, identity: identity,
            reason: "Second", location: "", contactInfo: "",
            outputUrl: secondUrl
        )

        let sigs = try PdfSigner.verifySignatures(pdfUrl: secondUrl)
        XCTAssertEqual(sigs.count, 2)
    }

    func test_signPdf_invalidPdf() {
        let garbage = Data("Not a PDF".utf8)
        let inputUrl = addTemp(TestPdfBuilder.writeTempFile(garbage, name: "garbage.pdf"))
        let outputUrl = addTemp(TestPdfBuilder.writeTempFile(Data(), name: "output.pdf"))

        // Need a dummy identity — generate one
        do {
            _ = try CertificateManager.generateSelfSigned(
                commonName: "Test", organization: "", country: "",
                validityDays: 1, alias: testAlias
            )
            let identity = try CertificateManager.getSigningIdentity(alias: testAlias)

            XCTAssertThrowsError(try PdfSigner.signPdf(
                pdfUrl: inputUrl, identity: identity,
                reason: "", location: "", contactInfo: "",
                outputUrl: outputUrl
            ))
        } catch {
            XCTFail("Setup failed: \(error)")
        }
    }

    func test_verifySignatures_unsignedPdf() throws {
        let pdfData = TestPdfBuilder.minimalPdf()
        let url = addTemp(TestPdfBuilder.writeTempFile(pdfData, name: "unsigned.pdf"))

        let sigs = try PdfSigner.verifySignatures(pdfUrl: url)
        XCTAssertTrue(sigs.isEmpty)
    }
}
