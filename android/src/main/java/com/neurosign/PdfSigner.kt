package com.neurosign

import java.io.File
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.*

/**
 * PAdES-B-B PDF signer for Android.
 * Implements proper PDF incremental update with AcroForm, SignatureField,
 * Widget Annotation, cross-reference table, and CMS/PKCS#7 container.
 *
 * Delegates to:
 * - [PdfParser] for PDF structure parsing
 * - [PdfImageOverlay] for visual signature image overlay
 * - [CmsBuilder] for CMS/PKCS#7 container construction
 * - [PdfVerifier] for signature verification
 */
object PdfSigner {

    private const val CONTENTS_PLACEHOLDER_SIZE = 16384

    // MARK: - Data Types

    private data class IncrementalUpdateResult(
        val bytes: ByteArray,
        val contentsHexOffset: Int,
        val byteRangePlaceholderOffset: Int,
        val byteRangePlaceholderLength: Int
    )

    // MARK: - Add Signature Image (delegates to PdfImageOverlay)

    fun addSignatureImage(
        pdfFile: File,
        rgbBytes: ByteArray,
        alphaBytes: ByteArray?,
        imageWidth: Int,
        imageHeight: Int,
        pageIndex: Int,
        x: Float,
        y: Float,
        width: Float,
        height: Float,
        outputFile: File
    ) {
        PdfImageOverlay.addSignatureImage(
            pdfFile, rgbBytes, alphaBytes, imageWidth, imageHeight,
            pageIndex, x, y, width, height, outputFile
        )
    }

    // MARK: - Sign PDF

    fun signPdf(
        pdfFile: File,
        identity: CertificateManager.SigningIdentity,
        reason: String,
        location: String,
        contactInfo: String,
        tsaUrl: String? = null,
        outputFile: File
    ) {
        val pdfBytes = pdfFile.readBytes()
        val pdfText = String(pdfBytes, Charsets.US_ASCII)

        val eofPos = PdfParser.findEOF(pdfBytes)
            ?: throw IllegalStateException("Invalid PDF: %%EOF not found")

        val trailer = PdfParser.parseTrailer(pdfBytes, eofPos)
        val firstPageNum = PdfParser.findFirstPageObjNum(pdfText, trailer.rootObjNum)
        val pageInfo = PdfParser.readPageInfo(pdfText, firstPageNum)
        val rootDictContent = PdfParser.findObjectDict(pdfText, trailer.rootObjNum)
            ?: throw IllegalStateException("Cannot read Root catalog")

        val appendPoint = PdfParser.findAppendPoint(pdfBytes, eofPos)

        val update = buildIncrementalUpdate(
            trailer = trailer,
            pageInfo = pageInfo,
            rootDictContent = rootDictContent,
            reason = reason,
            location = location,
            contactInfo = contactInfo,
            appendOffset = appendPoint,
            pdfText = pdfText
        )

        var fullPdf = ByteArray(appendPoint + update.bytes.size)
        System.arraycopy(pdfBytes, 0, fullPdf, 0, appendPoint)
        System.arraycopy(update.bytes, 0, fullPdf, appendPoint, update.bytes.size)

        // Calculate ByteRange — gap covers <hex_digits> including angle brackets
        val contentsGapStart = appendPoint + update.contentsHexOffset
        val contentsGapEnd = contentsGapStart + 1 + CONTENTS_PLACEHOLDER_SIZE * 2 + 1
        val byteRange = intArrayOf(0, contentsGapStart, contentsGapEnd, fullPdf.size - contentsGapEnd)

        // Replace ByteRange placeholder
        val byteRangeStr = "[${byteRange[0]} ${byteRange[1]} ${byteRange[2]} ${byteRange[3]}]"
        val paddedByteRange = byteRangeStr.padEnd(update.byteRangePlaceholderLength)
        PdfParser.replaceBytes(
            fullPdf,
            "[0 0000000000 0000000000 0000000000]".toByteArray(),
            paddedByteRange.toByteArray(),
            appendPoint
        )

        // Hash the byte ranges
        val digest = MessageDigest.getInstance("SHA-256")
        if (byteRange[1] > 0) digest.update(fullPdf, byteRange[0], byteRange[1])
        if (byteRange[3] > 0) digest.update(fullPdf, byteRange[2], byteRange[3])
        val hash = digest.digest()

        // Build CMS container (with optional RFC 3161 timestamp for PAdES-B-T)
        val cmsContainer = CmsBuilder.buildCMSContainer(hash, identity, tsaUrl)
        val hexEncoded = cmsContainer.joinToString("") { "%02x".format(it) }
        val paddedHex = hexEncoded.padEnd(CONTENTS_PLACEHOLDER_SIZE * 2, '0')
        PdfParser.replaceBytes(
            fullPdf,
            "0".repeat(CONTENTS_PLACEHOLDER_SIZE * 2).toByteArray(),
            paddedHex.toByteArray(),
            appendPoint
        )

        outputFile.writeBytes(fullPdf)
    }

    // MARK: - External Signing

    fun prepareForExternalSigning(
        pdfFile: File,
        reason: String,
        location: String,
        contactInfo: String,
        outputFile: File
    ): Pair<ByteArray, String> {
        val pdfBytes = pdfFile.readBytes()
        val pdfText = String(pdfBytes, Charsets.US_ASCII)

        val eofPos = PdfParser.findEOF(pdfBytes)
            ?: throw IllegalStateException("Invalid PDF: %%EOF not found")
        val trailer = PdfParser.parseTrailer(pdfBytes, eofPos)
        val firstPageNum = PdfParser.findFirstPageObjNum(pdfText, trailer.rootObjNum)
        val pageInfo = PdfParser.readPageInfo(pdfText, firstPageNum)
        val rootDictContent = PdfParser.findObjectDict(pdfText, trailer.rootObjNum)
            ?: throw IllegalStateException("Cannot read Root catalog")

        val appendPoint = PdfParser.findAppendPoint(pdfBytes, eofPos)

        val update = buildIncrementalUpdate(
            trailer = trailer,
            pageInfo = pageInfo,
            rootDictContent = rootDictContent,
            reason = reason,
            location = location,
            contactInfo = contactInfo,
            appendOffset = appendPoint,
            pdfText = pdfText
        )

        val fullPdf = ByteArray(appendPoint + update.bytes.size)
        System.arraycopy(pdfBytes, 0, fullPdf, 0, appendPoint)
        System.arraycopy(update.bytes, 0, fullPdf, appendPoint, update.bytes.size)

        val contentsGapStart = appendPoint + update.contentsHexOffset
        val contentsGapEnd = contentsGapStart + 1 + CONTENTS_PLACEHOLDER_SIZE * 2 + 1
        val byteRange = intArrayOf(0, contentsGapStart, contentsGapEnd, fullPdf.size - contentsGapEnd)

        val byteRangeStr = "[${byteRange[0]} ${byteRange[1]} ${byteRange[2]} ${byteRange[3]}]"
        val paddedByteRange = byteRangeStr.padEnd(update.byteRangePlaceholderLength)
        PdfParser.replaceBytes(
            fullPdf,
            "[0 0000000000 0000000000 0000000000]".toByteArray(),
            paddedByteRange.toByteArray(),
            appendPoint
        )

        val digest = MessageDigest.getInstance("SHA-256")
        if (byteRange[1] > 0) digest.update(fullPdf, byteRange[0], byteRange[1])
        if (byteRange[3] > 0) digest.update(fullPdf, byteRange[2], byteRange[3])
        val hash = digest.digest()

        outputFile.writeBytes(fullPdf)
        return hash to "SHA-256"
    }

    fun completeExternalSigning(
        preparedPdfFile: File,
        cmsSignature: ByteArray,
        outputFile: File
    ) {
        val fullPdf = preparedPdfFile.readBytes()
        val hexEncoded = cmsSignature.joinToString("") { "%02x".format(it) }
        require(hexEncoded.length <= CONTENTS_PLACEHOLDER_SIZE * 2) {
            "CMS signature too large: ${cmsSignature.size} bytes (max $CONTENTS_PLACEHOLDER_SIZE)"
        }
        val paddedHex = hexEncoded.padEnd(CONTENTS_PLACEHOLDER_SIZE * 2, '0')
        PdfParser.replaceBytes(
            fullPdf,
            "0".repeat(CONTENTS_PLACEHOLDER_SIZE * 2).toByteArray(),
            paddedHex.toByteArray(),
            0
        )
        outputFile.writeBytes(fullPdf)
    }

    // MARK: - Verify Signatures (delegates to PdfVerifier)

    /**
     * Re-exported type alias for backward compatibility.
     */
    data class SignatureInfo(
        val signerName: String,
        val signedAt: String,
        val valid: Boolean,
        val trusted: Boolean,
        val reason: String
    )

    fun verifySignatures(pdfFile: File): List<SignatureInfo> {
        return PdfVerifier.verifySignatures(pdfFile).map {
            SignatureInfo(
                signerName = it.signerName,
                signedAt = it.signedAt,
                valid = it.valid,
                trusted = it.trusted,
                reason = it.reason
            )
        }
    }

    // MARK: - Private: Incremental Update Builder

    private fun generateUniqueFieldName(pdfText: String): String {
        var index = 1
        while (pdfText.contains("/T (Signature$index)")) {
            index++
        }
        return "Signature$index"
    }

    private fun buildIncrementalUpdate(
        trailer: PdfParser.TrailerInfo,
        pageInfo: PdfParser.PageInfo,
        rootDictContent: String,
        reason: String,
        location: String,
        contactInfo: String,
        appendOffset: Int,
        pdfText: String
    ): IncrementalUpdateResult {
        val sigObjNum = trailer.size
        val fieldObjNum = trailer.size + 1
        val newSize = trailer.size + 2

        val dateFormat = SimpleDateFormat("'D:'yyyyMMddHHmmss'+00''00'''", Locale.US)
        dateFormat.timeZone = TimeZone.getTimeZone("UTC")
        val dateStr = dateFormat.format(Date())

        val byteRangePlaceholder = "[0 0000000000 0000000000 0000000000]"
        val contentsPlaceholder = "0".repeat(CONTENTS_PLACEHOLDER_SIZE * 2)

        val xrefEntries = mutableListOf<Pair<Int, Int>>()
        val body = StringBuilder()
        body.append("\n")

        // Signature Value object
        val sigObjOffset = appendOffset + body.length
        xrefEntries.add(sigObjNum to sigObjOffset)

        body.append("$sigObjNum 0 obj\n")
        body.append("<<\n")
        body.append("/Type /Sig\n")
        body.append("/Filter /Adobe.PPKLite\n")
        body.append("/SubFilter /ETSI.CAdES.detached\n")
        body.append("/ByteRange $byteRangePlaceholder\n")

        val contentsLinePrefix = "/Contents "
        val contentsHexRelativeOffset = body.length + contentsLinePrefix.length
        body.append("$contentsLinePrefix<$contentsPlaceholder>\n")

        body.append("/Reason (${PdfParser.escapeParens(reason)})\n")
        body.append("/Location (${PdfParser.escapeParens(location)})\n")
        body.append("/ContactInfo (${PdfParser.escapeParens(contactInfo)})\n")
        body.append("/M ($dateStr)\n")
        body.append(">>\n")
        body.append("endobj\n\n")

        // Signature Field + Widget Annotation
        val fieldObjOffset = appendOffset + body.length
        xrefEntries.add(fieldObjNum to fieldObjOffset)

        body.append("$fieldObjNum 0 obj\n")
        body.append("<<\n")
        body.append("/Type /Annot\n")
        body.append("/Subtype /Widget\n")
        body.append("/FT /Sig\n")
        body.append("/T (${generateUniqueFieldName(pdfText)})\n")
        body.append("/V $sigObjNum 0 R\n")
        body.append("/Rect [0 0 0 0]\n")
        body.append("/F 132\n")
        body.append("/P ${pageInfo.objNum} 0 R\n")
        body.append(">>\n")
        body.append("endobj\n\n")

        // Updated Page (same objNum, new content)
        val updatedPageOffset = appendOffset + body.length
        xrefEntries.add(pageInfo.objNum to updatedPageOffset)

        var pageDictClean = pageInfo.dictContent
            .replace(Regex("/Annots\\s*\\[[^\\]]*]"), "")
            .trim()

        val annotRefs = buildList {
            pageInfo.existingAnnotRefs?.let { addAll(it) }
            add("$fieldObjNum 0 R")
        }.joinToString(" ")

        body.append("${pageInfo.objNum} 0 obj\n")
        body.append("<<\n")
        body.append("$pageDictClean\n")
        body.append("/Annots [$annotRefs]\n")
        body.append(">>\n")
        body.append("endobj\n\n")

        // Updated Catalog (same objNum, new content)
        val updatedCatalogOffset = appendOffset + body.length
        xrefEntries.add(trailer.rootObjNum to updatedCatalogOffset)

        var catalogDictClean = rootDictContent

        // Remove existing /AcroForm
        val acroFormIdx = catalogDictClean.indexOf("/AcroForm")
        if (acroFormIdx >= 0) {
            val afterAcroForm = catalogDictClean.substring(acroFormIdx + "/AcroForm".length).trimStart()
            if (afterAcroForm.startsWith("<<")) {
                var depth = 0
                var endIdx = acroFormIdx + "/AcroForm".length + (catalogDictClean.length - acroFormIdx - "/AcroForm".length - afterAcroForm.length)
                var j = endIdx
                while (j < catalogDictClean.length - 1) {
                    if (catalogDictClean[j] == '<' && catalogDictClean[j + 1] == '<') {
                        depth++; j += 2
                    } else if (catalogDictClean[j] == '>' && catalogDictClean[j + 1] == '>') {
                        depth--
                        if (depth == 0) {
                            catalogDictClean = catalogDictClean.removeRange(acroFormIdx, j + 2)
                            break
                        }
                        j += 2
                    } else {
                        j++
                    }
                }
            } else if (afterAcroForm.matches(Regex("^\\d+\\s+\\d+\\s+R.*", RegexOption.DOT_MATCHES_ALL))) {
                val refMatch = Regex("^(\\d+\\s+\\d+\\s+R)").find(afterAcroForm)
                if (refMatch != null) {
                    val fullLen = "/AcroForm".length + (catalogDictClean.length - acroFormIdx - "/AcroForm".length - afterAcroForm.length) + refMatch.value.length
                    catalogDictClean = catalogDictClean.removeRange(acroFormIdx, acroFormIdx + fullLen)
                }
            }
        }
        catalogDictClean = catalogDictClean.trim()

        // Collect existing AcroForm fields for re-signing support
        val existingFields = if (acroFormIdx >= 0) {
            val acroFormText = rootDictContent.substring(acroFormIdx)
            val fieldsMatch = Regex("/Fields\\s*\\[([^\\]]*)]").find(acroFormText)
            fieldsMatch?.let {
                Regex("(\\d+\\s+\\d+\\s+R)").findAll(it.groupValues[1])
                    .map { m -> m.value }
                    .toList()
            }
        } else null

        val fieldRefs = buildList {
            existingFields?.let { addAll(it) }
            add("$fieldObjNum 0 R")
        }.joinToString(" ")

        body.append("${trailer.rootObjNum} 0 obj\n")
        body.append("<<\n")
        body.append("$catalogDictClean\n")
        body.append("/AcroForm << /Fields [$fieldRefs] /SigFlags 3 >>\n")
        body.append(">>\n")
        body.append("endobj\n\n")

        // Cross-reference table
        val xrefOffset = appendOffset + body.length

        val sortedEntries = xrefEntries.sortedBy { it.first }
        body.append("xref\n")
        var i = 0
        while (i < sortedEntries.size) {
            val startObjNum = sortedEntries[i].first
            var endIdx = i
            while (endIdx + 1 < sortedEntries.size &&
                sortedEntries[endIdx + 1].first == sortedEntries[endIdx].first + 1
            ) {
                endIdx++
            }
            val count = endIdx - i + 1
            body.append("$startObjNum $count\n")
            for (k in i..endIdx) {
                body.append(String.format("%010d 00000 n \n", sortedEntries[k].second))
            }
            i = endIdx + 1
        }

        // Trailer
        body.append("trailer\n")
        body.append("<< /Size $newSize /Root ${trailer.rootObjNum} 0 R /Prev ${trailer.prevStartXref} >>\n")
        body.append("startxref\n")
        body.append("$xrefOffset\n")
        body.append("%%EOF\n")

        val bodyString = body.toString()
        val bodyBytes = bodyString.toByteArray(Charsets.US_ASCII)
        val brOffset = bodyString.indexOf(byteRangePlaceholder)

        return IncrementalUpdateResult(
            bytes = bodyBytes,
            contentsHexOffset = contentsHexRelativeOffset,
            byteRangePlaceholderOffset = brOffset,
            byteRangePlaceholderLength = byteRangePlaceholder.length
        )
    }
}
