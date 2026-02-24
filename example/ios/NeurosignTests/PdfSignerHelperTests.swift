import XCTest
@testable import Neurosign

final class PdfSignerHelperTests: XCTestCase {

    // MARK: - escapePdfString

    func test_escapePdfString_backslash() {
        XCTAssertEqual(PdfSigner.escapePdfString("a\\b"), "a\\\\b")
    }

    func test_escapePdfString_parentheses() {
        XCTAssertEqual(PdfSigner.escapePdfString("(hello)"), "\\(hello\\)")
    }

    func test_escapePdfString_newlineTabCR() {
        XCTAssertEqual(PdfSigner.escapePdfString("a\nb"), "a\\nb")
        XCTAssertEqual(PdfSigner.escapePdfString("a\tb"), "a\\tb")
        XCTAssertEqual(PdfSigner.escapePdfString("a\rb"), "a\\rb")
    }

    func test_escapePdfString_noOpForSafe() {
        XCTAssertEqual(PdfSigner.escapePdfString("Hello World"), "Hello World")
    }

    // MARK: - extractFirstInt

    func test_extractFirstInt_afterPrefix() {
        XCTAssertEqual(
            PdfSigner.extractFirstInt(from: "/Root 5 0 R", after: "/Root"),
            5
        )
    }

    func test_extractFirstInt_afterPrefix_notFound() {
        XCTAssertNil(
            PdfSigner.extractFirstInt(from: "/Pages 2 0 R", after: "/Root")
        )
    }

    func test_extractFirstInt_withPattern() {
        XCTAssertEqual(
            PdfSigner.extractFirstInt(from: "/Size 42", pattern: #"/Size\s+(\d+)"#),
            42
        )
    }

    func test_extractFirstInt_withPattern_notFound() {
        XCTAssertNil(
            PdfSigner.extractFirstInt(from: "no match here", pattern: #"/Size\s+(\d+)"#)
        )
    }

    // MARK: - hexToData

    func test_hexToData_validHex() {
        let result = PdfSigner.hexToData("DEADBEEF")
        XCTAssertNotNil(result)
        XCTAssertEqual([UInt8](result!), [0xDE, 0xAD, 0xBE, 0xEF])
    }

    func test_hexToData_lowercase() {
        let result = PdfSigner.hexToData("deadbeef")
        XCTAssertNotNil(result)
        XCTAssertEqual([UInt8](result!), [0xDE, 0xAD, 0xBE, 0xEF])
    }

    func test_hexToData_emptyString() {
        let result = PdfSigner.hexToData("")
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.count, 0)
    }

    // MARK: - parseDERLength

    func test_parseDERLength_shortForm() {
        let bytes: [UInt8] = [0x30, 0x05, 0x01, 0x02, 0x03, 0x04, 0x05]
        // At offset 1: length byte 0x05 → short form, newOffset = 2
        let (newOffset, length) = PdfSigner.parseDERLength(bytes, offset: 1)
        XCTAssertEqual(length, 5)
        XCTAssertEqual(newOffset, 2) // offset 1 + 1 byte consumed
    }

    func test_parseDERLength_longForm() {
        let bytes: [UInt8] = [0x82, 0x01, 0x00] // 0x82 = 2 length bytes follow, value = 256
        let (newOffset, length) = PdfSigner.parseDERLength(bytes, offset: 0)
        XCTAssertEqual(length, 256)
        XCTAssertEqual(newOffset, 3) // 0 + 1 (0x82) + 2 (length bytes)
    }
}
