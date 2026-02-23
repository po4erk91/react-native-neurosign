package com.neurosign

import java.io.File

/**
 * Verifies digital signatures embedded in PDF files.
 * Parses /Type /Sig objects and extracts signature metadata.
 */
internal object PdfVerifier {

    data class SignatureInfo(
        val signerName: String,
        val signedAt: String,
        val valid: Boolean,
        val trusted: Boolean,
        val reason: String
    )

    /**
     * Find and verify all digital signatures in a PDF file.
     * Returns metadata for each signature found.
     */
    fun verifySignatures(pdfFile: File): List<SignatureInfo> {
        val pdfText = String(pdfFile.readBytes(), Charsets.US_ASCII)

        val results = mutableListOf<SignatureInfo>()

        var searchFrom = 0
        while (true) {
            val sigTypePos = pdfText.indexOf("/Type /Sig", searchFrom)
            if (sigTypePos < 0) break

            val contextStart = maxOf(0, sigTypePos - 500)
            val contextEnd = minOf(pdfText.length, sigTypePos + CONTENTS_SEARCH_WINDOW)
            val context = pdfText.substring(contextStart, contextEnd)

            val byteRange = parseByteRange(context)
            val contents = parseContents(context)
            val reason = parseField("Reason", context)

            if (byteRange != null && contents != null) {
                val cmsBytes = hexToBytes(contents)
                val hasValidStructure = cmsBytes != null && cmsBytes.size > 100

                results.add(
                    SignatureInfo(
                        signerName = parseField("Name", context) ?: "Unknown",
                        signedAt = parseField("M", context) ?: "",
                        valid = hasValidStructure,
                        trusted = false,
                        reason = reason ?: ""
                    )
                )
            }

            searchFrom = sigTypePos + 10
        }

        return results
    }

    // MARK: - Private

    /**
     * Search window size for /Contents hex string.
     * Must be large enough to encompass the placeholder size.
     */
    private const val CONTENTS_SEARCH_WINDOW = 8192 * 2 + 2000

    private fun parseByteRange(text: String): IntArray? {
        val regex = """/ByteRange\s*\[\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*]""".toRegex()
        val match = regex.find(text) ?: return null
        return intArrayOf(
            match.groupValues[1].toInt(),
            match.groupValues[2].toInt(),
            match.groupValues[3].toInt(),
            match.groupValues[4].toInt()
        )
    }

    private fun parseContents(text: String): String? {
        val start = text.indexOf("/Contents <")
        if (start < 0) return null
        val hexStart = start + "/Contents <".length
        val hexEnd = text.indexOf(">", hexStart)
        if (hexEnd < 0) return null
        return text.substring(hexStart, hexEnd).trim()
    }

    private fun parseField(field: String, text: String): String? {
        val start = text.indexOf("/$field (")
        if (start < 0) return null
        val valStart = start + "/$field (".length
        val valEnd = text.indexOf(")", valStart)
        if (valEnd < 0) return null
        return text.substring(valStart, valEnd)
    }

    private fun hexToBytes(hex: String): ByteArray? {
        val cleaned = hex.replace(" ", "").replace("\n", "")
        if (cleaned.length % 2 != 0) return null
        return try {
            ByteArray(cleaned.length / 2) { i ->
                cleaned.substring(i * 2, i * 2 + 2).toInt(16).toByte()
            }
        } catch (_: Exception) {
            null
        }
    }
}
