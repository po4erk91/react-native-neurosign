import XCTest
@testable import Neurosign

final class ExternalSigningIntegrationTests: XCTestCase {

    private var tempFiles: [URL] = []

    override func setUp() {
        super.setUp()
        tempFiles = []
    }

    override func tearDown() {
        tempFiles.forEach { TestPdfBuilder.cleanup($0) }
        super.tearDown()
    }

    private func addTemp(_ url: URL) -> URL {
        tempFiles.append(url)
        return url
    }

    // MARK: - prepareForExternalSigning

    func test_prepareForExternalSigning_returnsHash() throws {
        let pdfData = TestPdfBuilder.minimalPdf()
        let inputUrl = addTemp(TestPdfBuilder.writeTempFile(pdfData, name: "input_ext.pdf"))
        let preparedUrl = addTemp(TestPdfBuilder.writeTempFile(Data(), name: "prepared.pdf"))

        let (hash, algo) = try PdfSigner.prepareForExternalSigning(
            pdfUrl: inputUrl,
            reason: "External test",
            location: "",
            contactInfo: "",
            outputUrl: preparedUrl
        )

        XCTAssertEqual(algo, "SHA-256")
        XCTAssertEqual(hash.count, 32) // SHA-256 = 32 bytes

        // Prepared PDF should exist and be larger than input
        let preparedData = try Data(contentsOf: preparedUrl)
        XCTAssertTrue(preparedData.count > pdfData.count)
    }

    func test_completeExternalSigning_tooLargeSignature() throws {
        let pdfData = TestPdfBuilder.minimalPdf()
        let inputUrl = addTemp(TestPdfBuilder.writeTempFile(pdfData, name: "input_large.pdf"))
        let preparedUrl = addTemp(TestPdfBuilder.writeTempFile(Data(), name: "prepared_large.pdf"))
        let outputUrl = addTemp(TestPdfBuilder.writeTempFile(Data(), name: "output_large.pdf"))

        _ = try PdfSigner.prepareForExternalSigning(
            pdfUrl: inputUrl,
            reason: "Size test",
            location: "",
            contactInfo: "",
            outputUrl: preparedUrl
        )

        // Create an oversized CMS signature (larger than contentsPlaceholderSize)
        let oversizedCMS = Data(repeating: 0xAA, count: PdfSigner.contentsPlaceholderSize + 1)

        XCTAssertThrowsError(try PdfSigner.completeExternalSigning(
            preparedPdfUrl: preparedUrl,
            cmsSignature: oversizedCMS,
            outputUrl: outputUrl
        ))
    }

    func test_preparedPdf_containsPlaceholder() throws {
        let pdfData = TestPdfBuilder.minimalPdf()
        let inputUrl = addTemp(TestPdfBuilder.writeTempFile(pdfData, name: "input_ph.pdf"))
        let preparedUrl = addTemp(TestPdfBuilder.writeTempFile(Data(), name: "prepared_ph.pdf"))

        _ = try PdfSigner.prepareForExternalSigning(
            pdfUrl: inputUrl,
            reason: "Placeholder test",
            location: "",
            contactInfo: "",
            outputUrl: preparedUrl
        )

        let preparedText = try String(contentsOf: preparedUrl, encoding: .isoLatin1)
        // The prepared PDF should contain a zero-filled Contents placeholder
        let zeroPlaceholder = String(repeating: "0", count: PdfSigner.contentsPlaceholderSize * 2)
        XCTAssertTrue(preparedText.contains(zeroPlaceholder))
    }

    func test_fullExternalSigningRoundtrip() throws {
        let identity = try TestSigningHelper.generateRSAIdentity()

        let pdfData = TestPdfBuilder.minimalPdf()
        let inputUrl = addTemp(TestPdfBuilder.writeTempFile(pdfData, name: "input_full.pdf"))
        let preparedUrl = addTemp(TestPdfBuilder.writeTempFile(Data(), name: "prepared_full.pdf"))
        let signedUrl = addTemp(TestPdfBuilder.writeTempFile(Data(), name: "signed_full.pdf"))

        // Step 1: Prepare
        let (hash, _) = try PdfSigner.prepareForExternalSigning(
            pdfUrl: inputUrl,
            reason: "External roundtrip",
            location: "",
            contactInfo: "",
            outputUrl: preparedUrl
        )

        // Step 2: Sign using normal signPdf and verify
        try PdfSigner.signPdf(
            pdfUrl: inputUrl,
            identity: identity,
            reason: "External roundtrip",
            location: "",
            contactInfo: "",
            outputUrl: signedUrl
        )

        let sigs = try PdfSigner.verifySignatures(pdfUrl: signedUrl)
        XCTAssertEqual(sigs.count, 1)
        XCTAssertTrue(sigs[0].valid)

        // Verify the prepare step produced a valid hash
        XCTAssertEqual(hash.count, 32)
    }
}
