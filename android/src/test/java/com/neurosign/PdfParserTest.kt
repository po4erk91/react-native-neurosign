package com.neurosign

import org.junit.Assert.*
import org.junit.Test

class PdfParserTest {

    // MARK: - findEOF

    @Test
    fun findEOF_standardPdf() {
        val pdf = TestPdfBuilder.minimalPdf()
        val eofPos = PdfParser.findEOF(pdf)
        assertNotNull(eofPos)
        val marker = "%%EOF".toByteArray()
        for (i in marker.indices) {
            assertEquals(marker[i], pdf[eofPos!! + i])
        }
    }

    @Test
    fun findEOF_missing() {
        val bytes = "Just some random text without EOF marker".toByteArray()
        assertNull(PdfParser.findEOF(bytes))
    }

    @Test
    fun findEOF_trailingNewlines() {
        val pdf = TestPdfBuilder.minimalPdf()
        // Append extra newlines after the PDF
        val extended = pdf + "\n\n".toByteArray()
        val eofPos = PdfParser.findEOF(extended)
        assertNotNull(eofPos)
        val text = String(extended, eofPos!!, 5, Charsets.US_ASCII)
        assertEquals("%%EOF", text)
    }

    // MARK: - parseTrailer

    @Test
    fun parseTrailer_traditional() {
        val pdf = TestPdfBuilder.minimalPdf()
        val eofPos = PdfParser.findEOF(pdf)!!
        val trailer = PdfParser.parseTrailer(pdf, eofPos)
        assertEquals(1, trailer.rootObjNum)
        assertEquals(4, trailer.size)
    }

    @Test(expected = IllegalStateException::class)
    fun parseTrailer_garbage() {
        val bytes = "just garbage data %%EOF\n".toByteArray()
        val eofPos = PdfParser.findEOF(bytes)!!
        PdfParser.parseTrailer(bytes, eofPos)
    }

    // MARK: - findObjectDict

    @Test
    fun findObjectDict_lastDefinition() {
        val pdf = TestPdfBuilder.pdfWithIncrementalUpdate()
        val text = String(pdf, Charsets.US_ASCII)
        val dict = PdfParser.findObjectDict(text, 3)
        assertNotNull(dict)
        // Should find the LAST definition (800x600), not the first (612x792)
        assertTrue(dict!!.contains("800"))
        assertTrue(dict.contains("600"))
    }

    @Test
    fun findObjectDict_nestedDicts() {
        val text = "5 0 obj\n<< /Type /Catalog /AcroForm << /Fields [1 0 R] /SigFlags 3 >> >>\nendobj\n"
        val dict = PdfParser.findObjectDict(text, 5)
        assertNotNull(dict)
        assertTrue(dict!!.contains("/AcroForm"))
        assertTrue(dict.contains("/Fields"))
    }

    @Test
    fun findObjectDict_wordBoundary() {
        // "12 0 obj" should NOT match when searching for obj 2
        val text = "12 0 obj\n<< /Type /Wrong >>\nendobj\n2 0 obj\n<< /Type /Correct >>\nendobj\n"
        val dict = PdfParser.findObjectDict(text, 2)
        assertNotNull(dict)
        assertTrue(dict!!.contains("/Correct"))
        assertFalse(dict.contains("/Wrong"))
    }

    @Test
    fun findObjectDict_notFound() {
        val text = "1 0 obj\n<< /Type /Catalog >>\nendobj\n"
        assertNull(PdfParser.findObjectDict(text, 99))
    }

    // MARK: - findFirstPageObjNum

    @Test
    fun findFirstPageObjNum_standard() {
        val pdf = TestPdfBuilder.minimalPdf()
        val text = String(pdf, Charsets.US_ASCII)
        val pageNum = PdfParser.findFirstPageObjNum(text, 1) // Root = obj 1
        assertEquals(3, pageNum) // Page = obj 3
    }

    // MARK: - findPageObjNumByIndex

    @Test
    fun findPageObjNumByIndex_valid() {
        val pdf = TestPdfBuilder.minimalPdf()
        val text = String(pdf, Charsets.US_ASCII)
        val pageNum = PdfParser.findPageObjNumByIndex(text, 1, 0)
        assertEquals(3, pageNum)
    }

    @Test(expected = IllegalStateException::class)
    fun findPageObjNumByIndex_outOfRange() {
        val pdf = TestPdfBuilder.minimalPdf()
        val text = String(pdf, Charsets.US_ASCII)
        PdfParser.findPageObjNumByIndex(text, 1, 5) // Only 1 page
    }

    // MARK: - readPageInfo

    @Test
    fun readPageInfo_noAnnots() {
        val pdf = TestPdfBuilder.minimalPdf()
        val text = String(pdf, Charsets.US_ASCII)
        val info = PdfParser.readPageInfo(text, 3)
        assertEquals(3, info.objNum)
        assertNull(info.existingAnnotRefs)
    }

    @Test
    fun readPageInfo_withAnnots() {
        val pdf = TestPdfBuilder.minimalPdfWithAnnots(listOf("10 0 R", "11 0 R"))
        val text = String(pdf, Charsets.US_ASCII)
        val info = PdfParser.readPageInfo(text, 3)
        assertNotNull(info.existingAnnotRefs)
        assertEquals(2, info.existingAnnotRefs!!.size)
        assertTrue(info.existingAnnotRefs!!.contains("10 0 R"))
        assertTrue(info.existingAnnotRefs!!.contains("11 0 R"))
    }

    // MARK: - readPageMediaBox

    @Test
    fun readPageMediaBox_present() {
        val pdf = TestPdfBuilder.minimalPdf()
        val text = String(pdf, Charsets.US_ASCII)
        val box = PdfParser.readPageMediaBox(text, 3)
        assertEquals(0f, box[0], 0.01f)
        assertEquals(0f, box[1], 0.01f)
        assertEquals(612f, box[2], 0.01f)
        assertEquals(792f, box[3], 0.01f)
    }

    @Test
    fun readPageMediaBox_fallback() {
        // Object that doesn't exist → fallback to letter size
        val box = PdfParser.readPageMediaBox("no such object", 999)
        assertEquals(612f, box[2], 0.01f)
        assertEquals(792f, box[3], 0.01f)
    }

    // MARK: - indexOf

    @Test
    fun indexOf_found() {
        val data = "Hello World".toByteArray()
        val target = "World".toByteArray()
        assertEquals(6, PdfParser.indexOf(data, target, 0))
    }

    @Test
    fun indexOf_notFound() {
        val data = "Hello World".toByteArray()
        val target = "xyz".toByteArray()
        assertEquals(-1, PdfParser.indexOf(data, target, 0))
    }

    // MARK: - findAppendPoint

    @Test
    fun findAppendPoint_afterEOF() {
        val pdf = TestPdfBuilder.minimalPdf()
        val eofPos = PdfParser.findEOF(pdf)!!
        val appendPoint = PdfParser.findAppendPoint(pdf, eofPos)
        // Should be past %%EOF and any trailing newlines
        assertTrue(appendPoint >= eofPos + 5)
        assertTrue(appendPoint <= pdf.size)
    }

    // MARK: - escapeParens

    @Test
    fun escapeParens_parentheses() {
        assertEquals("\\(hello\\)", PdfParser.escapeParens("(hello)"))
    }

    @Test
    fun escapeParens_backslash() {
        assertEquals("a\\\\b", PdfParser.escapeParens("a\\b"))
    }

    @Test
    fun escapeParens_safe() {
        assertEquals("Hello World", PdfParser.escapeParens("Hello World"))
    }

    // MARK: - formatFloat

    @Test
    fun formatFloat_standard() {
        val result = PdfParser.formatFloat(123.456f)
        assertTrue(result.contains("123.45"))
        // Should use '.' not ',' regardless of locale
        assertFalse(result.contains(","))
    }

    // MARK: - buildXrefAndTrailer

    @Test
    fun buildXrefAndTrailer_correctFormat() {
        val entries = listOf(4 to 1000, 5 to 2000)
        val result = PdfParser.buildXrefAndTrailer(
            xrefEntries = entries,
            xrefOffset = 3000,
            newSize = 6,
            rootObjNum = 1,
            prevStartXref = 500
        )
        assertTrue(result.contains("xref"))
        assertTrue(result.contains("4 2")) // consecutive entries grouped
        assertTrue(result.contains("/Size 6"))
        assertTrue(result.contains("/Root 1 0 R"))
        assertTrue(result.contains("/Prev 500"))
        assertTrue(result.contains("startxref"))
        assertTrue(result.contains("3000"))
        assertTrue(result.contains("%%EOF"))
    }
}
