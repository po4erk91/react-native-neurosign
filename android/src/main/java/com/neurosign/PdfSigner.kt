package com.neurosign

import org.bouncycastle.asn1.ASN1EncodableVector
import org.bouncycastle.asn1.ASN1Integer
import org.bouncycastle.asn1.ASN1ObjectIdentifier
import org.bouncycastle.asn1.ASN1Sequence
import org.bouncycastle.asn1.ASN1Set
import org.bouncycastle.asn1.ASN1TaggedObject
import org.bouncycastle.asn1.DERNull
import org.bouncycastle.asn1.DEROctetString
import org.bouncycastle.asn1.DERSequence
import org.bouncycastle.asn1.DERSet
import org.bouncycastle.asn1.cms.Attribute
import org.bouncycastle.asn1.cms.AttributeTable
import org.bouncycastle.asn1.cms.CMSAttributes
import org.bouncycastle.asn1.cms.ContentInfo
import org.bouncycastle.asn1.cms.SignedData
import org.bouncycastle.asn1.cms.SignerInfo
import org.bouncycastle.asn1.ess.ESSCertIDv2
import org.bouncycastle.asn1.ess.SigningCertificateV2
import org.bouncycastle.asn1.nist.NISTObjectIdentifiers
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.asn1.x509.AlgorithmIdentifier
import org.bouncycastle.asn1.x509.GeneralName
import org.bouncycastle.asn1.x509.GeneralNames
import org.bouncycastle.asn1.x509.IssuerSerial
import org.bouncycastle.cert.jcajce.JcaCertStore
import org.bouncycastle.cms.CMSAbsentContent
import org.bouncycastle.cms.CMSAttributeTableGenerator
import org.bouncycastle.cms.CMSSignedData
import org.bouncycastle.cms.CMSSignedDataGenerator
import org.bouncycastle.cms.DefaultSignedAttributeTableGenerator
import org.bouncycastle.cms.jcajce.JcaSignerInfoGeneratorBuilder
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import org.bouncycastle.operator.jcajce.JcaDigestCalculatorProviderBuilder
import java.io.File
import java.security.MessageDigest
import java.security.cert.X509Certificate
import java.text.SimpleDateFormat
import java.util.*

/**
 * PAdES-B-B PDF signer for Android.
 * Implements proper PDF incremental update with AcroForm, SignatureField,
 * Widget Annotation, cross-reference table, and CMS/PKCS#7 container.
 */
object PdfSigner {

    private const val CONTENTS_PLACEHOLDER_SIZE = 8192

    // MARK: - PDF Structure Parsing

    private data class TrailerInfo(
        val rootObjNum: Int,
        val size: Int,
        val prevStartXref: Int
    )

    private data class PageInfo(
        val objNum: Int,
        val dictContent: String,
        val existingAnnotRefs: List<String>?
    )

    /**
     * Parse the PDF trailer to extract /Root object number, /Size, and previous startxref.
     * Handles both traditional xref+trailer and xref stream formats.
     */
    private fun parseTrailer(bytes: ByteArray, eofPos: Int): TrailerInfo {
        val text = String(bytes, 0, minOf(eofPos + 10, bytes.size), Charsets.US_ASCII)

        // Find startxref value
        val startxrefIdx = text.lastIndexOf("startxref")
        if (startxrefIdx < 0) throw IllegalStateException("startxref not found")

        val afterStartxref = text.substring(startxrefIdx + "startxref".length).trim()
        val prevStartXref = afterStartxref.split(Regex("\\s+"))[0].toInt()

        // Try to find traditional trailer
        val trailerIdx = text.lastIndexOf("trailer", startxrefIdx)

        if (trailerIdx >= 0) {
            val trailerText = text.substring(trailerIdx, startxrefIdx)

            val rootMatch = Regex("/Root\\s+(\\d+)\\s+\\d+\\s+R").find(trailerText)
                ?: throw IllegalStateException("Cannot find /Root in trailer")
            val sizeMatch = Regex("/Size\\s+(\\d+)").find(trailerText)
                ?: throw IllegalStateException("Cannot find /Size in trailer")

            return TrailerInfo(
                rootObjNum = rootMatch.groupValues[1].toInt(),
                size = sizeMatch.groupValues[1].toInt(),
                prevStartXref = prevStartXref
            )
        }

        // Xref stream: read the object at prevStartXref offset
        val streamObj = text.substring(prevStartXref, minOf(prevStartXref + 2000, text.length))
        val rootMatch = Regex("/Root\\s+(\\d+)\\s+\\d+\\s+R").find(streamObj)
            ?: throw IllegalStateException("Cannot find /Root in xref stream")
        val sizeMatch = Regex("/Size\\s+(\\d+)").find(streamObj)
            ?: throw IllegalStateException("Cannot find /Size in xref stream")

        return TrailerInfo(
            rootObjNum = rootMatch.groupValues[1].toInt(),
            size = sizeMatch.groupValues[1].toInt(),
            prevStartXref = prevStartXref
        )
    }

    /**
     * Find the dictionary content of a PDF indirect object by its object number.
     * Returns the text between the outermost << and >> (inclusive of nesting).
     */
    private fun findObjectDict(bytes: ByteArray, objNum: Int): String? {
        val text = String(bytes, Charsets.US_ASCII)
        val objHeader = "$objNum 0 obj"

        // Search for exact object header with word boundary (not inside "12 0 obj")
        var objIdx = -1
        var searchFrom = 0
        while (true) {
            val idx = text.indexOf(objHeader, searchFrom)
            if (idx < 0) break
            // Check that char before is not a digit (to avoid matching "12 0 obj" for "2 0 obj")
            if (idx == 0 || !text[idx - 1].isDigit()) {
                objIdx = idx
                break
            }
            searchFrom = idx + 1
        }
        if (objIdx < 0) return null

        val afterObj = objIdx + objHeader.length
        // Find the first <<
        val dictStart = text.indexOf("<<", afterObj)
        if (dictStart < 0) return null

        // Track nesting depth to find matching >>
        var depth = 0
        var i = dictStart
        while (i < text.length - 1) {
            if (text[i] == '<' && text[i + 1] == '<') {
                depth++
                i += 2
            } else if (text[i] == '>' && text[i + 1] == '>') {
                depth--
                if (depth == 0) {
                    return text.substring(dictStart + 2, i).trim()
                }
                i += 2
            } else {
                i++
            }
        }
        return null
    }

    /**
     * Resolve the first page object number from Root -> Pages -> Kids[0].
     */
    private fun findFirstPageObjNum(bytes: ByteArray, rootObjNum: Int): Int {
        val rootDict = findObjectDict(bytes, rootObjNum)
            ?: throw IllegalStateException("Cannot read Root catalog object $rootObjNum")

        val pagesMatch = Regex("/Pages\\s+(\\d+)\\s+\\d+\\s+R").find(rootDict)
            ?: throw IllegalStateException("Cannot find /Pages in catalog")
        val pagesObjNum = pagesMatch.groupValues[1].toInt()

        val pagesDict = findObjectDict(bytes, pagesObjNum)
            ?: throw IllegalStateException("Cannot read Pages object $pagesObjNum")

        val kidsMatch = Regex("/Kids\\s*\\[\\s*(\\d+)\\s+\\d+\\s+R").find(pagesDict)
            ?: throw IllegalStateException("Cannot find /Kids in Pages")

        return kidsMatch.groupValues[1].toInt()
    }

    /**
     * Read a page's dictionary content and extract existing /Annots references.
     */
    private fun readPageInfo(bytes: ByteArray, pageObjNum: Int): PageInfo {
        val dictContent = findObjectDict(bytes, pageObjNum)
            ?: throw IllegalStateException("Cannot read page object $pageObjNum")

        // Check for existing /Annots
        val annotsMatch = Regex("/Annots\\s*\\[([^\\]]*)]").find(dictContent)
        val existingAnnotRefs = if (annotsMatch != null) {
            Regex("(\\d+\\s+\\d+\\s+R)").findAll(annotsMatch.groupValues[1])
                .map { it.value }
                .toList()
        } else {
            null
        }

        return PageInfo(
            objNum = pageObjNum,
            dictContent = dictContent,
            existingAnnotRefs = existingAnnotRefs
        )
    }

    // MARK: - Page Helpers for Image Overlay

    /**
     * Resolve a page object number by 0-based index.
     * Navigates Root -> Pages -> Kids array.
     * Assumes flat page tree (all pages are direct children of root Pages node).
     */
    private fun findPageObjNumByIndex(bytes: ByteArray, rootObjNum: Int, pageIndex: Int): Int {
        val rootDict = findObjectDict(bytes, rootObjNum)
            ?: throw IllegalStateException("Cannot read Root catalog object $rootObjNum")

        val pagesMatch = Regex("/Pages\\s+(\\d+)\\s+\\d+\\s+R").find(rootDict)
            ?: throw IllegalStateException("Cannot find /Pages in catalog")
        val pagesObjNum = pagesMatch.groupValues[1].toInt()

        val pagesDict = findObjectDict(bytes, pagesObjNum)
            ?: throw IllegalStateException("Cannot read Pages object $pagesObjNum")

        val kidsMatch = Regex("/Kids\\s*\\[([^\\]]*)]").find(pagesDict)
            ?: throw IllegalStateException("Cannot find /Kids in Pages")
        val kidsStr = kidsMatch.groupValues[1]
        val kidRefs = Regex("(\\d+)\\s+\\d+\\s+R").findAll(kidsStr)
            .map { it.groupValues[1].toInt() }
            .toList()

        if (pageIndex < 0 || pageIndex >= kidRefs.size) {
            throw IllegalStateException("pageIndex $pageIndex out of range (0..${kidRefs.size - 1})")
        }

        return kidRefs[pageIndex]
    }

    /**
     * Read the /MediaBox from a page dictionary.
     * Returns [llx, lly, urx, ury] (lower-left x, lower-left y, upper-right x, upper-right y).
     * Falls back to Letter size (612x792) if not found.
     */
    private fun readPageMediaBox(bytes: ByteArray, pageObjNum: Int): FloatArray {
        val dictContent = findObjectDict(bytes, pageObjNum)
            ?: return floatArrayOf(0f, 0f, 612f, 792f)

        val mediaBoxMatch = Regex("/MediaBox\\s*\\[\\s*([\\d.\\-]+)\\s+([\\d.\\-]+)\\s+([\\d.\\-]+)\\s+([\\d.\\-]+)\\s*]")
            .find(dictContent)

        return if (mediaBoxMatch != null) {
            floatArrayOf(
                mediaBoxMatch.groupValues[1].toFloat(),
                mediaBoxMatch.groupValues[2].toFloat(),
                mediaBoxMatch.groupValues[3].toFloat(),
                mediaBoxMatch.groupValues[4].toFloat()
            )
        } else {
            floatArrayOf(0f, 0f, 612f, 792f)
        }
    }

    /**
     * Build updated page dictionary that adds an image XObject and content stream overlay.
     * - Appends content stream ref to /Contents (converts single ref to array if needed)
     * - Adds /SigImg to /Resources /XObject (resolves indirect /Resources if needed)
     */
    private fun buildUpdatedPageDict(
        bytes: ByteArray,
        originalDictContent: String,
        pageObjNum: Int,
        imgObjNum: Int,
        contentStreamObjNum: Int
    ): String {
        var dictContent = originalDictContent

        // 1. Handle /Contents — append new content stream reference
        val contentsArrayMatch = Regex("/Contents\\s*\\[([^\\]]*)]").find(dictContent)
        val contentsSingleMatch = Regex("/Contents\\s+(\\d+\\s+\\d+\\s+R)").find(dictContent)

        if (contentsArrayMatch != null) {
            val existingRefs = contentsArrayMatch.groupValues[1].trim()
            val newContents = "/Contents [$existingRefs $contentStreamObjNum 0 R]"
            dictContent = dictContent.replaceRange(contentsArrayMatch.range, newContents)
        } else if (contentsSingleMatch != null) {
            val existingRef = contentsSingleMatch.groupValues[1]
            val newContents = "/Contents [$existingRef $contentStreamObjNum 0 R]"
            dictContent = dictContent.replaceRange(contentsSingleMatch.range, newContents)
        } else {
            dictContent += "\n/Contents [$contentStreamObjNum 0 R]"
        }

        // 2. Handle /Resources /XObject — add SigImg reference
        // First check for inline /XObject dict
        val xobjectMatch = Regex("/XObject\\s*<<([^>]*>>|[^>]*)>>").find(dictContent)
        if (xobjectMatch != null) {
            // Existing inline /XObject dict — append to it
            val fullMatch = xobjectMatch.value
            val insertPos = fullMatch.lastIndexOf(">>")
            val newXObject = fullMatch.substring(0, insertPos) + " /SigImg $imgObjNum 0 R " + fullMatch.substring(insertPos)
            dictContent = dictContent.replaceRange(xobjectMatch.range, newXObject)
        } else {
            // Check if /Resources is inline
            val resourcesInlineMatch = Regex("/Resources\\s*<<").find(dictContent)
            val resourcesRefMatch = Regex("/Resources\\s+(\\d+)\\s+(\\d+)\\s+R").find(dictContent)

            if (resourcesInlineMatch != null) {
                // Insert /XObject inside existing inline /Resources
                val insertPos = resourcesInlineMatch.range.last + 1
                val xobjectStr = " /XObject << /SigImg $imgObjNum 0 R >>"
                dictContent = dictContent.substring(0, insertPos) + xobjectStr + dictContent.substring(insertPos)
            } else if (resourcesRefMatch != null) {
                // Indirect /Resources reference — resolve, inline, and add XObject
                val resObjNum = resourcesRefMatch.groupValues[1].toInt()
                val resDictContent = findObjectDict(bytes, resObjNum)
                if (resDictContent != null) {
                    // Check if resolved Resources has /XObject
                    val resXObjectMatch = Regex("/XObject\\s*<<([^>]*>>|[^>]*)>>").find(resDictContent)
                    val newResContent = if (resXObjectMatch != null) {
                        val fullMatch = resXObjectMatch.value
                        val ip = fullMatch.lastIndexOf(">>")
                        val updatedXObj = fullMatch.substring(0, ip) + " /SigImg $imgObjNum 0 R " + fullMatch.substring(ip)
                        resDictContent.replaceRange(resXObjectMatch.range, updatedXObj)
                    } else {
                        "$resDictContent /XObject << /SigImg $imgObjNum 0 R >>"
                    }
                    // Replace indirect ref with inline dict
                    dictContent = dictContent.replaceRange(
                        resourcesRefMatch.range,
                        "/Resources << $newResContent >>"
                    )
                } else {
                    // Cannot resolve — add new inline /Resources
                    dictContent += "\n/Resources << /XObject << /SigImg $imgObjNum 0 R >> >>"
                }
            } else {
                // No /Resources at all — add one
                dictContent += "\n/Resources << /XObject << /SigImg $imgObjNum 0 R >> >>"
            }
        }

        val sb = StringBuilder()
        sb.append("$pageObjNum 0 obj\n")
        sb.append("<<\n")
        sb.append("$dictContent\n")
        sb.append(">>\n")
        sb.append("endobj\n\n")
        return sb.toString()
    }

    /**
     * Build xref table and trailer for an incremental update.
     */
    private fun buildXrefAndTrailer(
        xrefEntries: List<Pair<Int, Int>>,
        xrefOffset: Int,
        newSize: Int,
        rootObjNum: Int,
        prevStartXref: Int
    ): String {
        val sb = StringBuilder()
        val sortedEntries = xrefEntries.sortedBy { it.first }

        sb.append("xref\n")
        var i = 0
        while (i < sortedEntries.size) {
            val startObjNum = sortedEntries[i].first
            var endIdx = i
            while (endIdx + 1 < sortedEntries.size &&
                sortedEntries[endIdx + 1].first == sortedEntries[endIdx].first + 1) {
                endIdx++
            }
            val count = endIdx - i + 1
            sb.append("$startObjNum $count\n")
            for (k in i..endIdx) {
                sb.append(String.format("%010d 00000 n \n", sortedEntries[k].second))
            }
            i = endIdx + 1
        }

        sb.append("trailer\n")
        sb.append("<< /Size $newSize /Root $rootObjNum 0 R /Prev $prevStartXref >>\n")
        sb.append("startxref\n")
        sb.append("$xrefOffset\n")
        sb.append("%%EOF\n")
        return sb.toString()
    }

    // MARK: - Add Signature Image (Incremental Update)

    /**
     * Add a visual signature image to a PDF page using incremental update.
     * Preserves all existing vector content. Only the signature image is raster.
     *
     * @param pdfFile     Input PDF file
     * @param imageBytes  JPEG-encoded signature image bytes
     * @param imageWidth  Image width in pixels
     * @param imageHeight Image height in pixels
     * @param pageIndex   0-based page index
     * @param x           Normalized X position (0-1, left-to-right)
     * @param y           Normalized Y position (0-1, top-to-bottom)
     * @param width       Normalized width (0-1)
     * @param height      Normalized height (0-1)
     * @param outputFile  Output PDF file
     */
    fun addSignatureImage(
        pdfFile: File,
        imageBytes: ByteArray,
        imageWidth: Int,
        imageHeight: Int,
        pageIndex: Int,
        x: Float,
        y: Float,
        width: Float,
        height: Float,
        outputFile: File
    ) {
        val pdfBytes = pdfFile.readBytes()

        val eofPos = findEOF(pdfBytes)
            ?: throw IllegalStateException("Invalid PDF: %%EOF not found")

        val trailer = parseTrailer(pdfBytes, eofPos)
        val pageObjNum = findPageObjNumByIndex(pdfBytes, trailer.rootObjNum, pageIndex)
        val pageDict = findObjectDict(pdfBytes, pageObjNum)
            ?: throw IllegalStateException("Cannot read page object $pageObjNum")
        val mediaBox = readPageMediaBox(pdfBytes, pageObjNum)

        // Calculate signature rectangle in PDF coordinates (bottom-up Y axis)
        val pageWidth = mediaBox[2] - mediaBox[0]
        val pageHeight = mediaBox[3] - mediaBox[1]
        val sigX = x * pageWidth + mediaBox[0]
        val sigY = (1f - y - height) * pageHeight + mediaBox[1] // flip Y: top-down → bottom-up
        val sigW = width * pageWidth
        val sigH = height * pageHeight

        // Find append point after %%EOF
        var appendPoint = eofPos + "%%EOF".length
        while (appendPoint < pdfBytes.size &&
            (pdfBytes[appendPoint] == '\n'.code.toByte() || pdfBytes[appendPoint] == '\r'.code.toByte())) {
            appendPoint++
        }

        // Assign object numbers for new objects
        val imgObjNum = trailer.size
        val contentStreamObjNum = trailer.size + 1
        val newSize = trailer.size + 2

        val xrefEntries = mutableListOf<Pair<Int, Int>>()

        // Use ByteArrayOutputStream to assemble binary + text data
        val updateStream = java.io.ByteArrayOutputStream()

        // Separator after previous %%EOF
        updateStream.write("\n".toByteArray(Charsets.US_ASCII))

        // ── Object 1: Image XObject ──
        val imgObjOffset = appendPoint + updateStream.size()
        xrefEntries.add(imgObjNum to imgObjOffset)

        val imgHeader = buildString {
            append("$imgObjNum 0 obj\n")
            append("<<\n")
            append("/Type /XObject\n")
            append("/Subtype /Image\n")
            append("/Width $imageWidth\n")
            append("/Height $imageHeight\n")
            append("/BitsPerComponent 8\n")
            append("/ColorSpace /DeviceRGB\n")
            append("/Filter /DCTDecode\n")
            append("/Length ${imageBytes.size}\n")
            append(">>\n")
            append("stream\n")
        }
        updateStream.write(imgHeader.toByteArray(Charsets.US_ASCII))
        updateStream.write(imageBytes)
        updateStream.write("\nendstream\nendobj\n\n".toByteArray(Charsets.US_ASCII))

        // ── Object 2: Content Stream overlay ──
        val csObjOffset = appendPoint + updateStream.size()
        xrefEntries.add(contentStreamObjNum to csObjOffset)

        // Format floats to avoid locale issues (always use '.' as decimal separator)
        val csContent = "q\n${formatFloat(sigW)} 0 0 ${formatFloat(sigH)} ${formatFloat(sigX)} ${formatFloat(sigY)} cm\n/SigImg Do\nQ\n"
        val csContentBytes = csContent.toByteArray(Charsets.US_ASCII)

        val csHeader = buildString {
            append("$contentStreamObjNum 0 obj\n")
            append("<< /Length ${csContentBytes.size} >>\n")
            append("stream\n")
        }
        updateStream.write(csHeader.toByteArray(Charsets.US_ASCII))
        updateStream.write(csContentBytes)
        updateStream.write("\nendstream\nendobj\n\n".toByteArray(Charsets.US_ASCII))

        // ── Object 3: Updated Page object ──
        val updatedPageOffset = appendPoint + updateStream.size()
        xrefEntries.add(pageObjNum to updatedPageOffset)

        val updatedPageStr = buildUpdatedPageDict(
            pdfBytes, pageDict, pageObjNum, imgObjNum, contentStreamObjNum
        )
        updateStream.write(updatedPageStr.toByteArray(Charsets.US_ASCII))

        // ── Cross-reference table + Trailer ──
        val xrefOffset = appendPoint + updateStream.size()
        val xrefStr = buildXrefAndTrailer(
            xrefEntries, xrefOffset, newSize, trailer.rootObjNum, trailer.prevStartXref
        )
        updateStream.write(xrefStr.toByteArray(Charsets.US_ASCII))

        // Assemble final PDF: original bytes + incremental update
        outputFile.outputStream().use { out ->
            out.write(pdfBytes, 0, appendPoint)
            out.write(updateStream.toByteArray())
        }
    }

    private fun formatFloat(value: Float): String {
        return String.format(java.util.Locale.US, "%.4f", value)
    }

    // MARK: - Incremental Update Builder

    private data class IncrementalUpdateResult(
        val bytes: ByteArray,
        val contentsHexOffset: Int,       // offset of '<' in Contents within bytes
        val byteRangePlaceholderOffset: Int,
        val byteRangePlaceholderLength: Int
    )

    /**
     * Build a complete PDF incremental update containing:
     * - Signature Value object (/Type /Sig)
     * - Signature Field + Widget Annotation object
     * - Updated Page object (with /Annots)
     * - Updated Catalog object (with /AcroForm)
     * - Cross-reference table
     * - Trailer with /Prev
     */
    private fun buildIncrementalUpdate(
        trailer: TrailerInfo,
        pageInfo: PageInfo,
        rootDictContent: String,
        reason: String,
        location: String,
        contactInfo: String,
        appendOffset: Int
    ): IncrementalUpdateResult {
        val sigObjNum = trailer.size
        val fieldObjNum = trailer.size + 1
        val newSize = trailer.size + 2

        val dateFormat = SimpleDateFormat("'D:'yyyyMMddHHmmss'+00''00'''", Locale.US)
        dateFormat.timeZone = TimeZone.getTimeZone("UTC")
        val dateStr = dateFormat.format(Date())

        val byteRangePlaceholder = "[0 0000000000 0000000000 0000000000]"
        val contentsPlaceholder = "0".repeat(CONTENTS_PLACEHOLDER_SIZE * 2)

        // Track offsets of each object
        val xrefEntries = mutableListOf<Pair<Int, Int>>() // objNum -> absolute offset

        val body = StringBuilder()
        body.append("\n") // separator after %%EOF

        // ── Object 1: Signature Value ──
        val sigObjOffset = appendOffset + body.length
        xrefEntries.add(sigObjNum to sigObjOffset)

        body.append("$sigObjNum 0 obj\n")
        body.append("<<\n")
        body.append("/Type /Sig\n")
        body.append("/Filter /Adobe.PPKLite\n")
        body.append("/SubFilter /ETSI.CAdES.detached\n")
        body.append("/ByteRange $byteRangePlaceholder\n")

        val contentsLinePrefix = "/Contents "
        // Point to '<' so ByteRange gap includes <hex> delimiters (per PDF spec / Adobe requirement)
        val contentsHexRelativeOffset = body.length + contentsLinePrefix.length
        body.append("$contentsLinePrefix<$contentsPlaceholder>\n")

        body.append("/Reason (${escapeParens(reason)})\n")
        body.append("/Location (${escapeParens(location)})\n")
        body.append("/ContactInfo (${escapeParens(contactInfo)})\n")
        body.append("/M ($dateStr)\n")
        body.append(">>\n")
        body.append("endobj\n\n")

        // ── Object 2: Signature Field + Widget Annotation ──
        val fieldObjOffset = appendOffset + body.length
        xrefEntries.add(fieldObjNum to fieldObjOffset)

        body.append("$fieldObjNum 0 obj\n")
        body.append("<<\n")
        body.append("/Type /Annot\n")
        body.append("/Subtype /Widget\n")
        body.append("/FT /Sig\n")
        body.append("/T (Signature1)\n")
        body.append("/V $sigObjNum 0 R\n")
        body.append("/Rect [0 0 0 0]\n")
        body.append("/F 132\n")
        body.append("/P ${pageInfo.objNum} 0 R\n")
        body.append(">>\n")
        body.append("endobj\n\n")

        // ── Object 3: Updated Page (same objNum, new content) ──
        val updatedPageOffset = appendOffset + body.length
        xrefEntries.add(pageInfo.objNum to updatedPageOffset)

        // Build new page dict: remove existing /Annots, add new one with merged refs
        var pageDictClean = pageInfo.dictContent
            .replace(Regex("/Annots\\s*\\[[^\\]]*]"), "") // remove existing /Annots
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

        // ── Object 4: Updated Catalog (same objNum, new content) ──
        val updatedCatalogOffset = appendOffset + body.length
        xrefEntries.add(trailer.rootObjNum to updatedCatalogOffset)

        // Build new catalog: remove existing /AcroForm, add new one
        var catalogDictClean = rootDictContent

        // Remove existing /AcroForm (handle nested << >>)
        val acroFormIdx = catalogDictClean.indexOf("/AcroForm")
        if (acroFormIdx >= 0) {
            // Find the extent of the /AcroForm value
            val afterAcroForm = catalogDictClean.substring(acroFormIdx + "/AcroForm".length).trimStart()
            if (afterAcroForm.startsWith("<<")) {
                // Inline dict — find matching >>
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
                // Indirect reference — remove /AcroForm N 0 R
                val refMatch = Regex("^(\\d+\\s+\\d+\\s+R)").find(afterAcroForm)
                if (refMatch != null) {
                    val fullLen = "/AcroForm".length + (catalogDictClean.length - acroFormIdx - "/AcroForm".length - afterAcroForm.length) + refMatch.value.length
                    catalogDictClean = catalogDictClean.removeRange(acroFormIdx, acroFormIdx + fullLen)
                }
            }
        }
        catalogDictClean = catalogDictClean.trim()

        // Collect existing fields from AcroForm if any (for re-signing support)
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

        // ── Cross-reference table ──
        val xrefOffset = appendOffset + body.length

        // Sort entries by object number
        val sortedEntries = xrefEntries.sortedBy { it.first }

        body.append("xref\n")
        // Write subsections: group contiguous object numbers
        var i = 0
        while (i < sortedEntries.size) {
            val startObjNum = sortedEntries[i].first
            var endIdx = i
            while (endIdx + 1 < sortedEntries.size &&
                sortedEntries[endIdx + 1].first == sortedEntries[endIdx].first + 1) {
                endIdx++
            }
            val count = endIdx - i + 1
            body.append("$startObjNum $count\n")
            for (k in i..endIdx) {
                body.append(String.format("%010d 00000 n \n", sortedEntries[k].second))
            }
            i = endIdx + 1
        }

        // ── Trailer ──
        body.append("trailer\n")
        body.append("<< /Size $newSize /Root ${trailer.rootObjNum} 0 R /Prev ${trailer.prevStartXref} >>\n")
        body.append("startxref\n")
        body.append("$xrefOffset\n")
        body.append("%%EOF\n")

        val bodyBytes = body.toString().toByteArray(Charsets.US_ASCII)

        // Calculate the ByteRange placeholder offset within the body
        val byteRangePlaceholderStr = byteRangePlaceholder
        val brOffset = body.toString().indexOf(byteRangePlaceholderStr)

        return IncrementalUpdateResult(
            bytes = bodyBytes,
            contentsHexOffset = contentsHexRelativeOffset,
            byteRangePlaceholderOffset = brOffset,
            byteRangePlaceholderLength = byteRangePlaceholder.length
        )
    }

    // MARK: - Sign PDF

    fun signPdf(
        pdfFile: File,
        identity: CertificateManager.SigningIdentity,
        reason: String,
        location: String,
        contactInfo: String,
        outputFile: File
    ) {
        val pdfBytes = pdfFile.readBytes()

        // Step 1: Parse existing PDF structure
        val eofPos = findEOF(pdfBytes)
            ?: throw IllegalStateException("Invalid PDF: %%EOF not found")

        val trailer = parseTrailer(pdfBytes, eofPos)
        val firstPageNum = findFirstPageObjNum(pdfBytes, trailer.rootObjNum)
        val pageInfo = readPageInfo(pdfBytes, firstPageNum)
        val rootDictContent = findObjectDict(pdfBytes, trailer.rootObjNum)
            ?: throw IllegalStateException("Cannot read Root catalog")

        // Step 2: Find append point (after %%EOF line)
        var appendPoint = eofPos + "%%EOF".length
        // Skip trailing newline(s) after %%EOF
        while (appendPoint < pdfBytes.size &&
            (pdfBytes[appendPoint] == '\n'.code.toByte() || pdfBytes[appendPoint] == '\r'.code.toByte())) {
            appendPoint++
        }

        // Step 3: Build incremental update
        val update = buildIncrementalUpdate(
            trailer = trailer,
            pageInfo = pageInfo,
            rootDictContent = rootDictContent,
            reason = reason,
            location = location,
            contactInfo = contactInfo,
            appendOffset = appendPoint
        )

        // Step 4: Combine original PDF + incremental update
        var fullPdf = ByteArray(appendPoint + update.bytes.size)
        System.arraycopy(pdfBytes, 0, fullPdf, 0, appendPoint)
        System.arraycopy(update.bytes, 0, fullPdf, appendPoint, update.bytes.size)

        // Step 5: Calculate ByteRange
        // Gap covers <hex_digits> including angle brackets (per PDF spec)
        val contentsGapStart = appendPoint + update.contentsHexOffset
        val contentsGapEnd = contentsGapStart + 1 + CONTENTS_PLACEHOLDER_SIZE * 2 + 1  // < + hex + >
        val byteRange = intArrayOf(
            0,
            contentsGapStart,
            contentsGapEnd,
            fullPdf.size - contentsGapEnd
        )

        // Step 6: Replace ByteRange placeholder with actual values
        val byteRangeStr = "[${byteRange[0]} ${byteRange[1]} ${byteRange[2]} ${byteRange[3]}]"
        val paddedByteRange = byteRangeStr.padEnd(update.byteRangePlaceholderLength)
        val byteRangePlaceholder = "[0 0000000000 0000000000 0000000000]"
        replaceBytes(fullPdf, byteRangePlaceholder.toByteArray(), paddedByteRange.toByteArray(), appendPoint)

        // Step 7: Hash the byte ranges
        val digest = MessageDigest.getInstance("SHA-256")
        if (byteRange[1] > 0) {
            digest.update(fullPdf, byteRange[0], byteRange[1])
        }
        if (byteRange[3] > 0) {
            digest.update(fullPdf, byteRange[2], byteRange[3])
        }
        val hash = digest.digest()

        // Step 8: Build CMS/PKCS#7 container (unchanged)
        val cmsContainer = buildCMSContainer(hash, identity)

        // Step 9: Embed CMS container into /Contents
        val hexEncoded = cmsContainer.joinToString("") { "%02x".format(it) }
        val paddedHex = hexEncoded.padEnd(CONTENTS_PLACEHOLDER_SIZE * 2, '0')
        val placeholder = "0".repeat(CONTENTS_PLACEHOLDER_SIZE * 2)
        replaceBytes(fullPdf, placeholder.toByteArray(), paddedHex.toByteArray(), appendPoint)

        // Step 10: Write output
        outputFile.writeBytes(fullPdf)
    }

    // MARK: - External Signing

    /**
     * Prepare a PDF for external signing: build incremental update, compute
     * ByteRange, and return the SHA-256 hash that needs to be signed externally.
     */
    fun prepareForExternalSigning(
        pdfFile: File,
        reason: String,
        location: String,
        contactInfo: String,
        outputFile: File
    ): Pair<ByteArray, String> {
        val pdfBytes = pdfFile.readBytes()

        val eofPos = findEOF(pdfBytes)
            ?: throw IllegalStateException("Invalid PDF: %%EOF not found")
        val trailer = parseTrailer(pdfBytes, eofPos)
        val firstPageNum = findFirstPageObjNum(pdfBytes, trailer.rootObjNum)
        val pageInfo = readPageInfo(pdfBytes, firstPageNum)
        val rootDictContent = findObjectDict(pdfBytes, trailer.rootObjNum)
            ?: throw IllegalStateException("Cannot read Root catalog")

        var appendPoint = eofPos + "%%EOF".length
        while (appendPoint < pdfBytes.size &&
            (pdfBytes[appendPoint] == '\n'.code.toByte() || pdfBytes[appendPoint] == '\r'.code.toByte())) {
            appendPoint++
        }

        val update = buildIncrementalUpdate(
            trailer = trailer,
            pageInfo = pageInfo,
            rootDictContent = rootDictContent,
            reason = reason,
            location = location,
            contactInfo = contactInfo,
            appendOffset = appendPoint
        )

        val fullPdf = ByteArray(appendPoint + update.bytes.size)
        System.arraycopy(pdfBytes, 0, fullPdf, 0, appendPoint)
        System.arraycopy(update.bytes, 0, fullPdf, appendPoint, update.bytes.size)

        val contentsGapStart = appendPoint + update.contentsHexOffset
        val contentsGapEnd = contentsGapStart + 1 + CONTENTS_PLACEHOLDER_SIZE * 2 + 1
        val byteRange = intArrayOf(0, contentsGapStart, contentsGapEnd, fullPdf.size - contentsGapEnd)

        val byteRangeStr = "[${byteRange[0]} ${byteRange[1]} ${byteRange[2]} ${byteRange[3]}]"
        val paddedByteRange = byteRangeStr.padEnd(update.byteRangePlaceholderLength)
        replaceBytes(fullPdf, "[0 0000000000 0000000000 0000000000]".toByteArray(), paddedByteRange.toByteArray(), appendPoint)

        val digest = MessageDigest.getInstance("SHA-256")
        if (byteRange[1] > 0) digest.update(fullPdf, byteRange[0], byteRange[1])
        if (byteRange[3] > 0) digest.update(fullPdf, byteRange[2], byteRange[3])
        val hash = digest.digest()

        outputFile.writeBytes(fullPdf)
        return hash to "SHA-256"
    }

    /**
     * Complete external signing by embedding a CMS/PKCS#7 signature
     * into the prepared PDF's /Contents placeholder.
     */
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
        val placeholder = "0".repeat(CONTENTS_PLACEHOLDER_SIZE * 2)
        replaceBytes(fullPdf, placeholder.toByteArray(), paddedHex.toByteArray(), 0)
        outputFile.writeBytes(fullPdf)
    }

    // MARK: - Verify Signatures

    data class SignatureInfo(
        val signerName: String,
        val signedAt: String,
        val valid: Boolean,
        val trusted: Boolean,
        val reason: String
    )

    fun verifySignatures(pdfFile: File): List<SignatureInfo> {
        val pdfBytes = pdfFile.readBytes()
        val pdfText = String(pdfBytes, Charsets.US_ASCII)

        val results = mutableListOf<SignatureInfo>()

        // Find /Type /Sig patterns
        var searchFrom = 0
        while (true) {
            val sigTypePos = pdfText.indexOf("/Type /Sig", searchFrom)
            if (sigTypePos < 0) break

            val contextStart = maxOf(0, sigTypePos - 500)
            val contextEnd = minOf(pdfText.length, sigTypePos + CONTENTS_PLACEHOLDER_SIZE * 2 + 2000)
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

    // MARK: - Private: Build CMS Container

    private fun buildCMSContainer(
        hash: ByteArray,
        identity: CertificateManager.SigningIdentity
    ): ByteArray {
        val certificate = identity.certificate
        val privateKey = identity.privateKey

        val generator = CMSSignedDataGenerator()

        // Auto-detect signature algorithm based on key type and size
        val signatureAlgorithm = when (privateKey.algorithm) {
            "EC", "ECDSA" -> {
                // Detect EC key size to choose appropriate hash
                val keySize = try {
                    val ecKey = privateKey as java.security.interfaces.ECPrivateKey
                    ecKey.params.order.bitLength()
                } catch (_: Exception) { 256 }
                if (keySize > 384) "SHA512withECDSA" else "SHA256withECDSA"
            }
            else -> "SHA256withRSA"
        }

        val contentSigner = JcaContentSignerBuilder(signatureAlgorithm)
            .build(privateKey)

        val digestCalculatorProvider = JcaDigestCalculatorProviderBuilder().build()

        // SHA-256 AlgorithmIdentifier with explicit NULL parameter.
        // Adobe Acrobat requires NULL in AlgorithmIdentifier for SHA-256,
        // even though RFC 5754 allows absent parameters.
        val sha256AlgId = AlgorithmIdentifier(NISTObjectIdentifiers.id_sha256, DERNull.INSTANCE)

        // Build ESSCertIDv2 for signing-certificate-v2 attribute (mandatory for PAdES B-B)
        val certHash = MessageDigest.getInstance("SHA-256").digest(certificate.encoded)
        val issuerName = GeneralName(X500Name.getInstance(certificate.issuerX500Principal.encoded))
        val issuerSerialObj = IssuerSerial(
            GeneralNames(issuerName),
            ASN1Integer(certificate.serialNumber)
        )

        // ESSCertIDv2 with IssuerSerial for full PAdES B-B compliance
        val signingCertV2 = SigningCertificateV2(arrayOf(
            ESSCertIDv2(
                sha256AlgId,
                certHash,
                issuerSerialObj
            )
        ))
        val sigCertV2Oid = ASN1ObjectIdentifier("1.2.840.113549.1.9.16.2.47")

        // Build signed attributes table with pre-computed messageDigest
        // and signing-certificate-v2 attribute.
        val attrsVector = ASN1EncodableVector()
        attrsVector.add(Attribute(CMSAttributes.messageDigest, DERSet(DEROctetString(hash))))
        attrsVector.add(Attribute(sigCertV2Oid, DERSet(signingCertV2)))
        val signedAttrsTable = AttributeTable(attrsVector)
        val baseGen = DefaultSignedAttributeTableGenerator(signedAttrsTable)

        // Strip out CMSAlgorithmProtection and signingTime attributes.
        // CMSAlgorithmProtection: BouncyCastle auto-adds but Adobe Acrobat may reject.
        // signingTime: not part of PAdES B-B profile.
        val cmsAlgProtectOid = ASN1ObjectIdentifier("1.2.840.113549.1.9.52")
        val signingTimeOid = ASN1ObjectIdentifier("1.2.840.113549.1.9.5")
        val signedAttrsGen = CMSAttributeTableGenerator { params ->
            var table = baseGen.getAttributes(params)
            table = table.remove(cmsAlgProtectOid)
            table = table.remove(signingTimeOid)
            table
        }

        val signerInfoGenerator = JcaSignerInfoGeneratorBuilder(digestCalculatorProvider)
            .setSignedAttributeGenerator(signedAttrsGen)
            .build(contentSigner, certificate)

        generator.addSignerInfoGenerator(signerInfoGenerator)

        val certStore = JcaCertStore(identity.certificateChain.toList())
        generator.addCertificates(certStore)

        // Use CMSAbsentContent for detached signature (no content to hash)
        val signedData = generator.generate(CMSAbsentContent(), false)

        // Post-process: ensure SHA-256 AlgorithmIdentifier includes NULL parameter.
        // BouncyCastle encodes SHA-256 AlgId as SEQUENCE { OID } (without NULL),
        // but Adobe Acrobat requires SEQUENCE { OID, NULL } for validation.
        return fixSha256AlgorithmIdentifier(signedData)
    }

    // MARK: - Private: Fix SHA-256 AlgorithmIdentifier

    /**
     * Fix SHA-256 AlgorithmIdentifier in CMS SignedData to include explicit NULL parameter.
     *
     * BouncyCastle encodes SHA-256 as: SEQUENCE { OID sha256 } (no NULL)
     * Adobe Acrobat requires:          SEQUENCE { OID sha256, NULL }
     *
     * This rebuilds the CMS structure, fixing digestAlgorithms SET and
     * signerInfo.digestAlgorithm, while preserving signed attributes
     * (which are already covered by the signature).
     */
    private fun fixSha256AlgorithmIdentifier(signedData: CMSSignedData): ByteArray {
        val contentInfo = signedData.toASN1Structure()
        val sd = SignedData.getInstance(contentInfo.content)

        val sha256WithNull = AlgorithmIdentifier(NISTObjectIdentifiers.id_sha256, DERNull.INSTANCE)

        // Fix digestAlgorithms SET
        val fixedDigestAlgs = ASN1EncodableVector()
        for (alg in sd.digestAlgorithms) {
            val algId = AlgorithmIdentifier.getInstance(alg)
            if (algId.algorithm == NISTObjectIdentifiers.id_sha256) {
                fixedDigestAlgs.add(sha256WithNull)
            } else {
                fixedDigestAlgs.add(algId)
            }
        }

        // Fix signerInfos
        val fixedSignerInfos = ASN1EncodableVector()
        for (si in sd.signerInfos) {
            val signerInfo = SignerInfo.getInstance(si)
            val fixedDigestAlg = if (signerInfo.digestAlgorithm.algorithm == NISTObjectIdentifiers.id_sha256) {
                sha256WithNull
            } else {
                signerInfo.digestAlgorithm
            }
            val fixedSignerInfo = SignerInfo(
                signerInfo.sid,
                fixedDigestAlg,
                signerInfo.authenticatedAttributes,
                signerInfo.digestEncryptionAlgorithm,
                signerInfo.encryptedDigest,
                signerInfo.unauthenticatedAttributes
            )
            fixedSignerInfos.add(fixedSignerInfo)
        }

        // Rebuild SignedData with fixed algorithms
        val fixedSD = SignedData(
            DERSet(fixedDigestAlgs),
            sd.encapContentInfo,
            sd.certificates,
            sd.getCRLs(),
            DERSet(fixedSignerInfos)
        )

        val fixedContentInfo = ContentInfo(contentInfo.contentType, fixedSD)
        return fixedContentInfo.getEncoded("DER")
    }

    // MARK: - Private: Helpers

    private fun findEOF(bytes: ByteArray): Int? {
        val marker = "%%EOF".toByteArray()
        for (i in bytes.size - marker.size downTo 0) {
            var match = true
            for (j in marker.indices) {
                if (bytes[i + j] != marker[j]) {
                    match = false
                    break
                }
            }
            if (match) return i
        }
        return null
    }

    private fun replaceBytes(
        data: ByteArray,
        target: ByteArray,
        replacement: ByteArray,
        searchFrom: Int
    ) {
        require(target.size == replacement.size) { "Target and replacement must be same length" }
        val pos = indexOf(data, target, searchFrom)
        if (pos >= 0) {
            System.arraycopy(replacement, 0, data, pos, replacement.size)
        }
    }

    private fun indexOf(data: ByteArray, target: ByteArray, fromIndex: Int): Int {
        outer@ for (i in fromIndex..data.size - target.size) {
            for (j in target.indices) {
                if (data[i + j] != target[j]) continue@outer
            }
            return i
        }
        return -1
    }

    private fun escapeParens(str: String): String {
        return str
            .replace("\\", "\\\\")
            .replace("(", "\\(")
            .replace(")", "\\)")
    }

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
