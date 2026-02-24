package com.neurosign

import java.io.File

/**
 * Helper to generate minimal valid PDFs for testing.
 */
object TestPdfBuilder {

    /**
     * Build a minimal valid single-page PDF with correct xref table and trailer.
     * Objects: 1=Catalog, 2=Pages, 3=Page.
     */
    fun minimalPdf(): ByteArray {
        val body = StringBuilder()
        body.append("%PDF-1.4\n")

        val obj1Offset = body.length
        body.append("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")

        val obj2Offset = body.length
        body.append("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n")

        val obj3Offset = body.length
        body.append("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\n")

        val xrefOffset = body.length
        body.append("xref\n")
        body.append("0 4\n")
        body.append("0000000000 65535 f \n")
        body.append(String.format("%010d 00000 n \n", obj1Offset))
        body.append(String.format("%010d 00000 n \n", obj2Offset))
        body.append(String.format("%010d 00000 n \n", obj3Offset))

        body.append("trailer\n")
        body.append("<< /Size 4 /Root 1 0 R >>\n")
        body.append("startxref\n")
        body.append("$xrefOffset\n")
        body.append("%%EOF\n")

        return body.toString().toByteArray(Charsets.US_ASCII)
    }

    /**
     * Build a minimal PDF with annotations on the page.
     */
    fun minimalPdfWithAnnots(annotRefs: List<String>): ByteArray {
        val body = StringBuilder()
        body.append("%PDF-1.4\n")

        val obj1Offset = body.length
        body.append("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")

        val obj2Offset = body.length
        body.append("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n")

        val annotsArray = annotRefs.joinToString(" ")
        val obj3Offset = body.length
        body.append("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [$annotsArray] >>\nendobj\n")

        val xrefOffset = body.length
        body.append("xref\n")
        body.append("0 4\n")
        body.append("0000000000 65535 f \n")
        body.append(String.format("%010d 00000 n \n", obj1Offset))
        body.append(String.format("%010d 00000 n \n", obj2Offset))
        body.append(String.format("%010d 00000 n \n", obj3Offset))

        body.append("trailer\n")
        body.append("<< /Size 4 /Root 1 0 R >>\n")
        body.append("startxref\n")
        body.append("$xrefOffset\n")
        body.append("%%EOF\n")

        return body.toString().toByteArray(Charsets.US_ASCII)
    }

    /**
     * Build a PDF with an incremental update (two definitions of the same object).
     */
    fun pdfWithIncrementalUpdate(): ByteArray {
        val body = StringBuilder()
        body.append("%PDF-1.4\n")

        val obj1Offset = body.length
        body.append("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")

        val obj2Offset = body.length
        body.append("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n")

        val obj3Offset = body.length
        body.append("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\n")

        val xrefOffset = body.length
        body.append("xref\n")
        body.append("0 4\n")
        body.append("0000000000 65535 f \n")
        body.append(String.format("%010d 00000 n \n", obj1Offset))
        body.append(String.format("%010d 00000 n \n", obj2Offset))
        body.append(String.format("%010d 00000 n \n", obj3Offset))

        body.append("trailer\n")
        body.append("<< /Size 4 /Root 1 0 R >>\n")
        body.append("startxref\n")
        body.append("$xrefOffset\n")
        body.append("%%EOF\n")

        // Incremental update: redefine object 3 with different MediaBox
        val newObj3Offset = body.length
        body.append("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 800 600] >>\nendobj\n")

        val newXrefOffset = body.length
        body.append("xref\n")
        body.append("3 1\n")
        body.append(String.format("%010d 00000 n \n", newObj3Offset))

        body.append("trailer\n")
        body.append("<< /Size 4 /Root 1 0 R /Prev $xrefOffset >>\n")
        body.append("startxref\n")
        body.append("$newXrefOffset\n")
        body.append("%%EOF\n")

        return body.toString().toByteArray(Charsets.US_ASCII)
    }

    /**
     * Write bytes to a temporary file and return it.
     */
    fun writeTempFile(data: ByteArray, name: String = "test.pdf"): File {
        val file = File.createTempFile("neurosign_test_", "_$name")
        file.writeBytes(data)
        return file
    }
}
