package com.neurosign

import org.junit.Assert.*
import org.junit.Test
import java.io.File

class PdfVerifierTest {

    // MARK: - verifySignatures

    @Test
    fun verifySignatures_unsignedPdf() {
        val pdf = TestPdfBuilder.minimalPdf()
        val file = TestPdfBuilder.writeTempFile(pdf)
        try {
            val results = PdfVerifier.verifySignatures(file)
            assertTrue(results.isEmpty())
        } finally {
            file.delete()
        }
    }

    @Test
    fun verifySignatures_withSigBlock() {
        // Build a PDF that contains a /Type /Sig dictionary with valid-looking Contents
        val validHex = "30" + "82" + "00ff" + "00".repeat(253) // 259 bytes > 100
        val sigDict = "/Type /Sig /ByteRange [0 100 200 300] /Contents <$validHex> /Reason (Test reason)"
        val body = StringBuilder()
        body.append("%PDF-1.4\n")
        body.append("1 0 obj\n<< $sigDict >>\nendobj\n")
        body.append("%%EOF\n")

        val file = TestPdfBuilder.writeTempFile(body.toString().toByteArray(Charsets.US_ASCII))
        try {
            val results = PdfVerifier.verifySignatures(file)
            assertEquals(1, results.size)
            assertEquals("Test reason", results[0].reason)
            assertFalse(results[0].trusted)
        } finally {
            file.delete()
        }
    }

    @Test
    fun verifySignatures_invalidCms_tooSmall() {
        // CMS hex < 100 bytes → valid should be false
        val smallHex = "AABB" // 2 bytes
        val sigDict = "/Type /Sig /ByteRange [0 100 200 300] /Contents <$smallHex> /Reason (Small)"
        val body = StringBuilder()
        body.append("%PDF-1.4\n")
        body.append("1 0 obj\n<< $sigDict >>\nendobj\n")
        body.append("%%EOF\n")

        val file = TestPdfBuilder.writeTempFile(body.toString().toByteArray(Charsets.US_ASCII))
        try {
            val results = PdfVerifier.verifySignatures(file)
            assertEquals(1, results.size)
            assertFalse(results[0].valid)
        } finally {
            file.delete()
        }
    }

    @Test
    fun verifySignatures_multipleSigs() {
        val validHex = "30" + "82" + "00ff" + "00".repeat(253)
        val padding = " ".repeat(20000) // Enough space between sigs
        val body = StringBuilder()
        body.append("%PDF-1.4\n")
        body.append("1 0 obj\n<< /Type /Sig /ByteRange [0 100 200 300] /Contents <$validHex> /Reason (First) >>\nendobj\n")
        body.append(padding)
        body.append("2 0 obj\n<< /Type /Sig /ByteRange [0 400 500 600] /Contents <$validHex> /Reason (Second) >>\nendobj\n")
        body.append("%%EOF\n")

        val file = TestPdfBuilder.writeTempFile(body.toString().toByteArray(Charsets.US_ASCII))
        try {
            val results = PdfVerifier.verifySignatures(file)
            assertEquals(2, results.size)
            assertEquals("First", results[0].reason)
            assertEquals("Second", results[1].reason)
        } finally {
            file.delete()
        }
    }

    @Test
    fun verifySignatures_noByteRange() {
        // /Type /Sig without /ByteRange → should not produce result
        val body = StringBuilder()
        body.append("%PDF-1.4\n")
        body.append("1 0 obj\n<< /Type /Sig /Contents <AABB> /Reason (NoBR) >>\nendobj\n")
        body.append("%%EOF\n")

        val file = TestPdfBuilder.writeTempFile(body.toString().toByteArray(Charsets.US_ASCII))
        try {
            val results = PdfVerifier.verifySignatures(file)
            assertTrue(results.isEmpty())
        } finally {
            file.delete()
        }
    }

    @Test
    fun verifySignatures_noContents() {
        // /Type /Sig with ByteRange but no /Contents → should not produce result
        val body = StringBuilder()
        body.append("%PDF-1.4\n")
        body.append("1 0 obj\n<< /Type /Sig /ByteRange [0 100 200 300] /Reason (NoCont) >>\nendobj\n")
        body.append("%%EOF\n")

        val file = TestPdfBuilder.writeTempFile(body.toString().toByteArray(Charsets.US_ASCII))
        try {
            val results = PdfVerifier.verifySignatures(file)
            assertTrue(results.isEmpty())
        } finally {
            file.delete()
        }
    }
}
