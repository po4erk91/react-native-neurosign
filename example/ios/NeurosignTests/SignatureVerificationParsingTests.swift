import XCTest
@testable import Neurosign

final class SignatureVerificationParsingTests: XCTestCase {

    // MARK: - parseByteRange

    func test_parseByteRange_valid() {
        let text = "/ByteRange [0 1234 5678 9012]"
        let result = PdfSigner.parseByteRange(from: text)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.0, 0)
        XCTAssertEqual(result!.1, 1234)
        XCTAssertEqual(result!.2, 5678)
        XCTAssertEqual(result!.3, 9012)
    }

    func test_parseByteRange_withExtraSpaces() {
        let text = "/ByteRange  [  0   100   200   300  ]"
        let result = PdfSigner.parseByteRange(from: text)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.0, 0)
        XCTAssertEqual(result!.3, 300)
    }

    func test_parseByteRange_missing() {
        let text = "/Contents <AABB>"
        XCTAssertNil(PdfSigner.parseByteRange(from: text))
    }

    // MARK: - parseContents

    func test_parseContents_valid() {
        let text = "/Contents <48656C6C6F>"
        let result = PdfSigner.parseContents(from: text)
        XCTAssertNotNil(result)
        XCTAssertEqual(result, "48656C6C6F")
    }

    func test_parseContents_missing() {
        let text = "/ByteRange [0 100 200 300]"
        XCTAssertNil(PdfSigner.parseContents(from: text))
    }

    // MARK: - parseField

    func test_parseField_simpleReason() {
        let text = "/Reason (Test signing)"
        let result = PdfSigner.parseField(named: "Reason", from: text)
        XCTAssertEqual(result, "Test signing")
    }

    func test_parseField_missing() {
        let text = "/Contents <AABB>"
        XCTAssertNil(PdfSigner.parseField(named: "Reason", from: text))
    }

    // MARK: - findSignatureDictionaries

    func test_findSignatureDictionaries_multiple() {
        // Build text with two /Type /Sig blocks spaced > 500 chars apart
        // (findSignatureDictionaries looks back 500 chars from /Type /Sig)
        let padding = String(repeating: " ", count: 600)
        var text = ""
        text += "<< /Type /Sig /Reason (First) /ByteRange [0 100 200 300] /Contents <AABB> >>"
        text += padding
        text += "<< /Type /Sig /Reason (Second) /ByteRange [0 400 500 600] /Contents <CCDD> >>"

        let results = PdfSigner.findSignatureDictionaries(in: text)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].reason, "First")
        XCTAssertEqual(results[1].reason, "Second")
    }

    func test_findSignatureDictionaries_none() {
        let text = "Just a regular PDF with no signatures at all"
        let results = PdfSigner.findSignatureDictionaries(in: text)
        XCTAssertTrue(results.isEmpty)
    }
}
