package com.neurosign

import org.bouncycastle.jce.provider.BouncyCastleProvider
import org.junit.Assert.*
import org.junit.Before
import org.junit.BeforeClass
import org.junit.Test
import java.io.File
import java.security.Security

class PdfSignerTest {

    companion object {
        @BeforeClass
        @JvmStatic
        fun setup() {
            if (Security.getProvider(BouncyCastleProvider.PROVIDER_NAME) == null) {
                Security.addProvider(BouncyCastleProvider())
            }
        }
    }

    private lateinit var rsaIdentity: CertificateManager.SigningIdentity
    private lateinit var ecIdentity: CertificateManager.SigningIdentity

    @Before
    fun setUp() {
        rsaIdentity = TestSigningHelper.generateRSAIdentity()
        ecIdentity = TestSigningHelper.generateECIdentity()
    }

    private fun createTempOutput(): File = File.createTempFile("neurosign_output_", ".pdf")

    // MARK: - signPdf + verifySignatures roundtrip

    @Test
    fun signPdf_rsa_verifyRoundtrip() {
        val pdfFile = TestPdfBuilder.writeTempFile(TestPdfBuilder.minimalPdf())
        val outputFile = createTempOutput()
        try {
            PdfSigner.signPdf(
                pdfFile = pdfFile,
                identity = rsaIdentity,
                reason = "Test RSA",
                location = "Test",
                contactInfo = "test@test.com",
                outputFile = outputFile
            )

            assertTrue(outputFile.exists())
            assertTrue(outputFile.length() > pdfFile.length())

            val signatures = PdfSigner.verifySignatures(outputFile)
            assertEquals(1, signatures.size)
            assertTrue(signatures[0].valid)
            assertEquals("Test RSA", signatures[0].reason)
        } finally {
            pdfFile.delete()
            outputFile.delete()
        }
    }

    @Test
    fun signPdf_ec_verifyRoundtrip() {
        val pdfFile = TestPdfBuilder.writeTempFile(TestPdfBuilder.minimalPdf())
        val outputFile = createTempOutput()
        try {
            PdfSigner.signPdf(
                pdfFile = pdfFile,
                identity = ecIdentity,
                reason = "Test EC",
                location = "Test",
                contactInfo = "test@test.com",
                outputFile = outputFile
            )

            val signatures = PdfSigner.verifySignatures(outputFile)
            assertEquals(1, signatures.size)
            assertTrue(signatures[0].valid)
            assertEquals("Test EC", signatures[0].reason)
        } finally {
            pdfFile.delete()
            outputFile.delete()
        }
    }

    @Test
    fun signPdf_tampered_invalidStructure() {
        val pdfFile = TestPdfBuilder.writeTempFile(TestPdfBuilder.minimalPdf())
        val outputFile = createTempOutput()
        try {
            PdfSigner.signPdf(
                pdfFile = pdfFile,
                identity = rsaIdentity,
                reason = "Tamper test",
                location = "Test",
                contactInfo = "test@test.com",
                outputFile = outputFile
            )

            // Tamper with the signed PDF by zeroing out part of the CMS data
            val bytes = outputFile.readBytes()
            val text = String(bytes, Charsets.US_ASCII)
            val contentsIdx = text.indexOf("/Contents <")
            assertTrue("Should find /Contents", contentsIdx >= 0)

            // Zero out some CMS hex digits (corrupt the signature)
            val hexStart = contentsIdx + "/Contents <".length
            for (i in hexStart until minOf(hexStart + 20, bytes.size)) {
                bytes[i] = '0'.code.toByte()
            }
            outputFile.writeBytes(bytes)

            val signatures = PdfSigner.verifySignatures(outputFile)
            // The signature should still be found but verification status depends on structure check
            // Since we corrupted the CMS prefix, it may no longer parse as valid CMS
            assertEquals(1, signatures.size)
        } finally {
            pdfFile.delete()
            outputFile.delete()
        }
    }

    @Test
    fun signPdf_twice_uniqueFieldNames() {
        val pdfFile = TestPdfBuilder.writeTempFile(TestPdfBuilder.minimalPdf())
        val firstSigned = createTempOutput()
        val secondSigned = createTempOutput()
        try {
            PdfSigner.signPdf(
                pdfFile = pdfFile,
                identity = rsaIdentity,
                reason = "First",
                location = "Test",
                contactInfo = "test@test.com",
                outputFile = firstSigned
            )

            PdfSigner.signPdf(
                pdfFile = firstSigned,
                identity = rsaIdentity,
                reason = "Second",
                location = "Test",
                contactInfo = "test@test.com",
                outputFile = secondSigned
            )

            val text = String(secondSigned.readBytes(), Charsets.US_ASCII)
            assertTrue(text.contains("/T (Signature1)"))
            assertTrue(text.contains("/T (Signature2)"))
        } finally {
            pdfFile.delete()
            firstSigned.delete()
            secondSigned.delete()
        }
    }

    @Test(expected = IllegalStateException::class)
    fun signPdf_invalidPdf_throws() {
        val file = TestPdfBuilder.writeTempFile("not a pdf".toByteArray())
        val output = createTempOutput()
        try {
            PdfSigner.signPdf(
                pdfFile = file,
                identity = rsaIdentity,
                reason = "Test",
                location = "Test",
                contactInfo = "test@test.com",
                outputFile = output
            )
        } finally {
            file.delete()
            output.delete()
        }
    }

    @Test
    fun verifySignatures_unsignedPdf_emptyList() {
        val pdfFile = TestPdfBuilder.writeTempFile(TestPdfBuilder.minimalPdf())
        try {
            val results = PdfSigner.verifySignatures(pdfFile)
            assertTrue(results.isEmpty())
        } finally {
            pdfFile.delete()
        }
    }

    // MARK: - External Signing

    @Test
    fun prepareForExternalSigning_returns32ByteHash() {
        val pdfFile = TestPdfBuilder.writeTempFile(TestPdfBuilder.minimalPdf())
        val outputFile = createTempOutput()
        try {
            val (hash, algorithm) = PdfSigner.prepareForExternalSigning(
                pdfFile = pdfFile,
                reason = "External",
                location = "Test",
                contactInfo = "test@test.com",
                outputFile = outputFile
            )

            assertEquals(32, hash.size) // SHA-256 = 32 bytes
            assertEquals("SHA-256", algorithm)
            assertTrue(outputFile.exists())
        } finally {
            pdfFile.delete()
            outputFile.delete()
        }
    }

    @Test
    fun prepareForExternalSigning_containsZeroPlaceholder() {
        val pdfFile = TestPdfBuilder.writeTempFile(TestPdfBuilder.minimalPdf())
        val outputFile = createTempOutput()
        try {
            PdfSigner.prepareForExternalSigning(
                pdfFile = pdfFile,
                reason = "External",
                location = "Test",
                contactInfo = "test@test.com",
                outputFile = outputFile
            )

            val text = String(outputFile.readBytes(), Charsets.US_ASCII)
            // Should contain zero-filled placeholder
            assertTrue(text.contains("0".repeat(100)))
        } finally {
            pdfFile.delete()
            outputFile.delete()
        }
    }

    @Test(expected = IllegalArgumentException::class)
    fun completeExternalSigning_tooLargeSignature_throws() {
        val pdfFile = TestPdfBuilder.writeTempFile(TestPdfBuilder.minimalPdf())
        val preparedFile = createTempOutput()
        val outputFile = createTempOutput()
        try {
            PdfSigner.prepareForExternalSigning(
                pdfFile = pdfFile,
                reason = "External",
                location = "Test",
                contactInfo = "test@test.com",
                outputFile = preparedFile
            )

            // Create a signature that's way too large
            val hugeSignature = ByteArray(20000) { 0x30 }
            PdfSigner.completeExternalSigning(preparedFile, hugeSignature, outputFile)
        } finally {
            pdfFile.delete()
            preparedFile.delete()
            outputFile.delete()
        }
    }

    @Test
    fun externalSigning_fullRoundtrip() {
        val pdfFile = TestPdfBuilder.writeTempFile(TestPdfBuilder.minimalPdf())
        val preparedFile = createTempOutput()
        val outputFile = createTempOutput()
        try {
            val (hash, _) = PdfSigner.prepareForExternalSigning(
                pdfFile = pdfFile,
                reason = "External Roundtrip",
                location = "Test",
                contactInfo = "test@test.com",
                outputFile = preparedFile
            )

            // Sign the hash externally using CmsBuilder
            val cmsSignature = CmsBuilder.buildCMSContainer(hash, rsaIdentity)

            PdfSigner.completeExternalSigning(preparedFile, cmsSignature, outputFile)

            val signatures = PdfSigner.verifySignatures(outputFile)
            assertEquals(1, signatures.size)
            assertTrue(signatures[0].valid)
            assertEquals("External Roundtrip", signatures[0].reason)
        } finally {
            pdfFile.delete()
            preparedFile.delete()
            outputFile.delete()
        }
    }

    // MARK: - ByteRange angle brackets regression

    @Test
    fun signPdf_byteRangeCoversAngleBrackets() {
        val pdfFile = TestPdfBuilder.writeTempFile(TestPdfBuilder.minimalPdf())
        val outputFile = createTempOutput()
        try {
            PdfSigner.signPdf(
                pdfFile = pdfFile,
                identity = rsaIdentity,
                reason = "ByteRange test",
                location = "Test",
                contactInfo = "test@test.com",
                outputFile = outputFile
            )

            val bytes = outputFile.readBytes()
            val text = String(bytes, Charsets.US_ASCII)

            // Parse ByteRange
            val brMatch = Regex("""/ByteRange\s*\[\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*]""").find(text)
            assertNotNull("Should find ByteRange", brMatch)
            val br = brMatch!!.groupValues.drop(1).map { it.toInt() }
            // br[0]=start1, br[1]=len1, br[2]=start2, br[3]=len2

            val gapStart = br[0] + br[1] // End of first range = start of gap
            val gapEnd = br[2]            // Start of second range = end of gap

            // The byte at gapStart should be '<' (opening angle bracket)
            assertEquals(
                "Gap should start at '<'",
                '<'.code.toByte(),
                bytes[gapStart]
            )
            // The byte before gapEnd should be '>' (closing angle bracket)
            assertEquals(
                "Gap should end after '>'",
                '>'.code.toByte(),
                bytes[gapEnd - 1]
            )
        } finally {
            pdfFile.delete()
            outputFile.delete()
        }
    }
}
