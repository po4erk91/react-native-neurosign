import XCTest
@testable import Neurosign

final class PdfParsingTests: XCTestCase {

    // MARK: - findEOF

    func test_findEOF_standardPdf() {
        let pdf = TestPdfBuilder.minimalPdf()
        let range = PdfSigner.findEOF(in: pdf)
        XCTAssertNotNil(range)

        // Verify the bytes at the range spell "%%EOF"
        let eofStr = String(data: pdf[range!], encoding: .utf8)
        XCTAssertEqual(eofStr, "%%EOF")
    }

    func test_findEOF_missingEOF() {
        let data = Data("Just some random text without EOF marker".utf8)
        XCTAssertNil(PdfSigner.findEOF(in: data))
    }

    func test_findEOF_withTrailingNewlines() {
        var pdf = TestPdfBuilder.minimalPdf()
        pdf.append(Data("\n\n\n".utf8))
        let range = PdfSigner.findEOF(in: pdf)
        XCTAssertNotNil(range)
    }

    // MARK: - parseTrailer

    func test_parseTrailer_traditionalTrailer() {
        let pdf = TestPdfBuilder.minimalPdf()
        let pdfText = String(data: pdf, encoding: .isoLatin1)!
        let eofRange = PdfSigner.findEOF(in: pdf)!

        let trailer = PdfSigner.parseTrailer(in: pdfText, eofPos: eofRange.lowerBound)
        XCTAssertNotNil(trailer)
        XCTAssertEqual(trailer!.rootObjNum, 1)
        XCTAssertEqual(trailer!.size, 4)
    }

    func test_parseTrailer_returnsNilForGarbage() {
        let text = "This is not a PDF at all, just random text"
        let trailer = PdfSigner.parseTrailer(in: text, eofPos: text.count)
        XCTAssertNil(trailer)
    }

    // MARK: - findObjectDict

    func test_findObjectDict_findsLastDefinition() {
        // In incremental updates, the LAST definition should win
        let pdf = TestPdfBuilder.pdfWithIncrementalUpdate()
        let pdfText = String(data: pdf, encoding: .isoLatin1)!

        let dict = PdfSigner.findObjectDict(in: pdfText, objNum: 3)
        XCTAssertNotNil(dict)
        // The incremental update changed MediaBox to 800x600
        XCTAssertTrue(dict!.contains("800 600"), "Should find the LAST (updated) definition")
    }

    func test_findObjectDict_nestedDicts() {
        let pdfText = "1 0 obj\n<< /Type /Catalog /Inner << /A /B >> /Pages 2 0 R >>\nendobj\n"
        let dict = PdfSigner.findObjectDict(in: pdfText, objNum: 1)
        XCTAssertNotNil(dict)
        XCTAssertTrue(dict!.contains("/Inner"))
        XCTAssertTrue(dict!.contains("/A /B"))
    }

    func test_findObjectDict_wordBoundary() {
        // "12 0 obj" should NOT match when searching for "2 0 obj"
        let pdfText = "12 0 obj\n<< /Type /Wrong >>\nendobj\n2 0 obj\n<< /Type /Correct >>\nendobj\n"
        let dict = PdfSigner.findObjectDict(in: pdfText, objNum: 2)
        XCTAssertNotNil(dict)
        XCTAssertTrue(dict!.contains("/Correct"))
        XCTAssertFalse(dict!.contains("/Wrong"))
    }

    // MARK: - findFirstPageObjNum

    func test_findFirstPageObjNum_standard() {
        let pdf = TestPdfBuilder.minimalPdf()
        let pdfText = String(data: pdf, encoding: .isoLatin1)!

        let pageNum = PdfSigner.findFirstPageObjNum(in: pdfText, rootObjNum: 1)
        XCTAssertEqual(pageNum, 3) // Catalog(1) -> Pages(2) -> Kids[3]
    }

    // MARK: - readPageInfo

    func test_readPageInfo_noAnnots() {
        let pdf = TestPdfBuilder.minimalPdf()
        let pdfText = String(data: pdf, encoding: .isoLatin1)!

        let info = PdfSigner.readPageInfo(in: pdfText, pageObjNum: 3)
        XCTAssertNotNil(info)
        XCTAssertEqual(info!.objNum, 3)
        XCTAssertNil(info!.existingAnnotRefs)
    }

    func test_readPageInfo_withAnnots() {
        let pdf = TestPdfBuilder.minimalPdfWithAnnots(annotRefs: ["10 0 R", "11 0 R"])
        let pdfText = String(data: pdf, encoding: .isoLatin1)!

        let info = PdfSigner.readPageInfo(in: pdfText, pageObjNum: 3)
        XCTAssertNotNil(info)
        XCTAssertNotNil(info!.existingAnnotRefs)
        XCTAssertEqual(info!.existingAnnotRefs?.count, 2)
    }

    // MARK: - generateUniqueFieldName

    func test_generateUniqueFieldName_noExisting() {
        let pdfText = "Some PDF text without any signature fields"
        let name = PdfSigner.generateUniqueFieldName(in: pdfText)
        XCTAssertEqual(name, "Signature1")
    }

    func test_generateUniqueFieldName_withExisting() {
        let pdfText = "Some text /T (Signature1) more text /T (Signature2) end"
        let name = PdfSigner.generateUniqueFieldName(in: pdfText)
        XCTAssertEqual(name, "Signature3")
    }
}
