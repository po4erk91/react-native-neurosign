import Foundation

/// Helper to generate minimal valid PDFs for testing.
enum TestPdfBuilder {

    /// Build a minimal valid single-page PDF with correct xref table and trailer.
    /// The resulting PDF has objects: 1=Catalog, 2=Pages, 3=Page.
    static func minimalPdf() -> Data {
        var body = ""
        body += "%PDF-1.4\n"

        // Object 1: Catalog
        let obj1Offset = body.count
        body += "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"

        // Object 2: Pages
        let obj2Offset = body.count
        body += "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n"

        // Object 3: Page
        let obj3Offset = body.count
        body += "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\n"

        // Xref table
        let xrefOffset = body.count
        body += "xref\n"
        body += "0 4\n"
        body += "0000000000 65535 f \n"
        body += String(format: "%010d 00000 n \n", obj1Offset)
        body += String(format: "%010d 00000 n \n", obj2Offset)
        body += String(format: "%010d 00000 n \n", obj3Offset)

        // Trailer
        body += "trailer\n"
        body += "<< /Size 4 /Root 1 0 R >>\n"
        body += "startxref\n"
        body += "\(xrefOffset)\n"
        body += "%%EOF\n"

        return Data(body.utf8)
    }

    /// Build a minimal PDF with annotations on the page.
    static func minimalPdfWithAnnots(annotRefs: [String]) -> Data {
        var body = ""
        body += "%PDF-1.4\n"

        let obj1Offset = body.count
        body += "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"

        let obj2Offset = body.count
        body += "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n"

        let annotsArray = annotRefs.joined(separator: " ")
        let obj3Offset = body.count
        body += "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [\(annotsArray)] >>\nendobj\n"

        let xrefOffset = body.count
        body += "xref\n"
        body += "0 4\n"
        body += "0000000000 65535 f \n"
        body += String(format: "%010d 00000 n \n", obj1Offset)
        body += String(format: "%010d 00000 n \n", obj2Offset)
        body += String(format: "%010d 00000 n \n", obj3Offset)

        body += "trailer\n"
        body += "<< /Size 4 /Root 1 0 R >>\n"
        body += "startxref\n"
        body += "\(xrefOffset)\n"
        body += "%%EOF\n"

        return Data(body.utf8)
    }

    /// Build a PDF with an incremental update (two definitions of the same object).
    static func pdfWithIncrementalUpdate() -> Data {
        // First: standard PDF
        var body = ""
        body += "%PDF-1.4\n"

        let obj1Offset = body.count
        body += "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"

        let obj2Offset = body.count
        body += "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n"

        let obj3Offset = body.count
        body += "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\n"

        let xrefOffset = body.count
        body += "xref\n"
        body += "0 4\n"
        body += "0000000000 65535 f \n"
        body += String(format: "%010d 00000 n \n", obj1Offset)
        body += String(format: "%010d 00000 n \n", obj2Offset)
        body += String(format: "%010d 00000 n \n", obj3Offset)

        body += "trailer\n"
        body += "<< /Size 4 /Root 1 0 R >>\n"
        body += "startxref\n"
        body += "\(xrefOffset)\n"
        body += "%%EOF\n"

        // Incremental update: redefine object 3 with different MediaBox
        let newObj3Offset = body.count
        body += "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 800 600] >>\nendobj\n"

        let newXrefOffset = body.count
        body += "xref\n"
        body += "3 1\n"
        body += String(format: "%010d 00000 n \n", newObj3Offset)

        body += "trailer\n"
        body += "<< /Size 4 /Root 1 0 R /Prev \(xrefOffset) >>\n"
        body += "startxref\n"
        body += "\(newXrefOffset)\n"
        body += "%%EOF\n"

        return Data(body.utf8)
    }

    /// Write Data to a temporary file and return the URL.
    static func writeTempFile(_ data: Data, name: String = "test.pdf") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)_\(name)")
        try! data.write(to: url)
        return url
    }

    /// Clean up a temporary file.
    static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
