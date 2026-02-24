package com.neurosign

import org.junit.Assert.*
import org.junit.Test
import java.io.File

class PdfGeneratorTest {

    /**
     * Create minimal valid JPEG bytes (smallest valid JPEG: SOI + EOI markers).
     * This is not a real image but enough for PDF structure testing.
     */
    private fun minimalJpegBytes(): ByteArray {
        // Minimal JPEG: SOI (FFD8) + APP0 marker + EOI (FFD9)
        // We use a tiny valid JPEG that most parsers accept
        return byteArrayOf(
            0xFF.toByte(), 0xD8.toByte(), // SOI
            0xFF.toByte(), 0xE0.toByte(), // APP0 marker
            0x00, 0x10,                   // Length = 16
            0x4A, 0x46, 0x49, 0x46, 0x00, // "JFIF\0"
            0x01, 0x01,                   // Version 1.1
            0x00,                         // Aspect ratio units
            0x00, 0x01,                   // X density
            0x00, 0x01,                   // Y density
            0x00, 0x00,                   // Thumbnail dimensions
            0xFF.toByte(), 0xD9.toByte()  // EOI
        )
    }

    @Test
    fun writePdfWithImages_singlePage_startsWithPdfHeader() {
        val outputFile = File.createTempFile("neurosign_gen_", ".pdf")
        try {
            val page = PdfGenerator.PageData(
                jpegBytes = minimalJpegBytes(),
                imgWidth = 100,
                imgHeight = 100,
                pageWidthPt = 612f,
                pageHeightPt = 792f,
                drawX = 0f,
                drawY = 0f,
                drawW = 612f,
                drawH = 792f
            )

            PdfGenerator.writePdfWithImages(outputFile, listOf(page))

            assertTrue(outputFile.exists())
            val bytes = outputFile.readBytes()
            val header = String(bytes, 0, 9, Charsets.US_ASCII)
            assertTrue("Should start with %PDF-1.4", header.startsWith("%PDF-1.4"))

            val text = String(bytes, Charsets.US_ASCII)
            assertTrue("Should contain %%EOF", text.contains("%%EOF"))
            assertTrue("Should contain xref", text.contains("xref"))
        } finally {
            outputFile.delete()
        }
    }

    @Test
    fun writePdfWithImages_multiplePages_correctCount() {
        val outputFile = File.createTempFile("neurosign_gen_", ".pdf")
        try {
            val pages = (1..3).map {
                PdfGenerator.PageData(
                    jpegBytes = minimalJpegBytes(),
                    imgWidth = 100,
                    imgHeight = 100,
                    pageWidthPt = 612f,
                    pageHeightPt = 792f,
                    drawX = 0f,
                    drawY = 0f,
                    drawW = 612f,
                    drawH = 792f
                )
            }

            PdfGenerator.writePdfWithImages(outputFile, pages)

            val text = String(outputFile.readBytes(), Charsets.US_ASCII)
            assertTrue("Should contain /Count 3", text.contains("/Count 3"))
            // Should have 3 page references in Kids array
            val kidsMatch = Regex("""/Kids\s*\[([^\]]*)]""").find(text)
            assertNotNull(kidsMatch)
            val refs = Regex("""\d+\s+0\s+R""").findAll(kidsMatch!!.groupValues[1]).count()
            assertEquals(3, refs)
        } finally {
            outputFile.delete()
        }
    }

    @Test
    fun writePdfWithImages_containsImageXObject() {
        val outputFile = File.createTempFile("neurosign_gen_", ".pdf")
        try {
            val page = PdfGenerator.PageData(
                jpegBytes = minimalJpegBytes(),
                imgWidth = 200,
                imgHeight = 300,
                pageWidthPt = 612f,
                pageHeightPt = 792f,
                drawX = 0f,
                drawY = 0f,
                drawW = 612f,
                drawH = 792f
            )

            PdfGenerator.writePdfWithImages(outputFile, listOf(page))

            val text = String(outputFile.readBytes(), Charsets.US_ASCII)
            assertTrue("Should contain image XObject", text.contains("/Type /XObject"))
            assertTrue("Should contain /Subtype /Image", text.contains("/Subtype /Image"))
            assertTrue("Should contain /Width 200", text.contains("/Width 200"))
            assertTrue("Should contain /Height 300", text.contains("/Height 300"))
            assertTrue("Should contain /DCTDecode", text.contains("/Filter /DCTDecode"))
        } finally {
            outputFile.delete()
        }
    }
}
