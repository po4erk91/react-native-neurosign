package com.neurosign

import java.io.File

/**
 * Adds a visual signature image to a PDF page using incremental update.
 * Preserves all existing vector content. Supports transparency via SMask.
 *
 * Uses Deflate compression for image data and builds proper PDF XObjects
 * with content stream overlays.
 */
internal object PdfImageOverlay {

    /**
     * Add a visual signature image to a PDF page using incremental update.
     *
     * @param pdfFile     Input PDF file
     * @param rgbBytes    Raw RGB pixel data (3 bytes per pixel, row-major)
     * @param alphaBytes  Raw alpha channel data (1 byte per pixel), null if fully opaque
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
        val pdfBytes = pdfFile.readBytes()
        val pdfText = String(pdfBytes, Charsets.US_ASCII)

        val eofPos = PdfParser.findEOF(pdfBytes)
            ?: throw IllegalStateException("Invalid PDF: %%EOF not found")

        val trailer = PdfParser.parseTrailer(pdfBytes, eofPos)
        val pageObjNum = PdfParser.findPageObjNumByIndex(pdfText, trailer.rootObjNum, pageIndex)
        val pageDict = PdfParser.findObjectDict(pdfText, pageObjNum)
            ?: throw IllegalStateException("Cannot read page object $pageObjNum")
        val mediaBox = PdfParser.readPageMediaBox(pdfText, pageObjNum)

        // Calculate signature rectangle in PDF coordinates (bottom-up Y axis)
        val pageWidth = mediaBox[2] - mediaBox[0]
        val pageHeight = mediaBox[3] - mediaBox[1]
        val sigX = x * pageWidth + mediaBox[0]
        val sigY = (1f - y - height) * pageHeight + mediaBox[1] // flip Y: top-down -> bottom-up
        val sigW = width * pageWidth
        val sigH = height * pageHeight

        val appendPoint = PdfParser.findAppendPoint(pdfBytes, eofPos)

        // Deflate-compress RGB data
        val deflater = java.util.zip.Deflater()
        try {
            val compressedRgb = deflateCompress(rgbBytes, deflater)

            // Assign object numbers
            val hasAlpha = alphaBytes != null
            val smaskObjNum = if (hasAlpha) trailer.size else -1
            val imgObjNum = if (hasAlpha) trailer.size + 1 else trailer.size
            val contentStreamObjNum = imgObjNum + 1
            val newSize = contentStreamObjNum + 1

            val xrefEntries = mutableListOf<Pair<Int, Int>>()
            val updateStream = java.io.ByteArrayOutputStream()

            updateStream.write("\n".toByteArray(Charsets.US_ASCII))

            // Optional: SMask XObject (alpha channel)
            if (alphaBytes != null) {
                val compressedAlpha = deflateCompress(alphaBytes, deflater)

                val smaskOffset = appendPoint + updateStream.size()
                xrefEntries.add(smaskObjNum to smaskOffset)

                val smaskHeader = buildString {
                    append("$smaskObjNum 0 obj\n")
                    append("<<\n")
                    append("/Type /XObject\n")
                    append("/Subtype /Image\n")
                    append("/Width $imageWidth\n")
                    append("/Height $imageHeight\n")
                    append("/BitsPerComponent 8\n")
                    append("/ColorSpace /DeviceGray\n")
                    append("/Filter /FlateDecode\n")
                    append("/Length ${compressedAlpha.size}\n")
                    append(">>\n")
                    append("stream\n")
                }
                updateStream.write(smaskHeader.toByteArray(Charsets.US_ASCII))
                updateStream.write(compressedAlpha)
                updateStream.write("\nendstream\nendobj\n\n".toByteArray(Charsets.US_ASCII))
            }

            // Image XObject (RGB)
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
                append("/Filter /FlateDecode\n")
                if (hasAlpha) append("/SMask $smaskObjNum 0 R\n")
                append("/Length ${compressedRgb.size}\n")
                append(">>\n")
                append("stream\n")
            }
            updateStream.write(imgHeader.toByteArray(Charsets.US_ASCII))
            updateStream.write(compressedRgb)
            updateStream.write("\nendstream\nendobj\n\n".toByteArray(Charsets.US_ASCII))

            // Content Stream overlay
            val csObjOffset = appendPoint + updateStream.size()
            xrefEntries.add(contentStreamObjNum to csObjOffset)

            val ff = PdfParser::formatFloat
            val csContent = "q\n${ff(sigW)} 0 0 ${ff(sigH)} ${ff(sigX)} ${ff(sigY)} cm\n/SigImg Do\nQ\n"
            val csContentBytes = csContent.toByteArray(Charsets.US_ASCII)

            val csHeader = buildString {
                append("$contentStreamObjNum 0 obj\n")
                append("<< /Length ${csContentBytes.size} >>\n")
                append("stream\n")
            }
            updateStream.write(csHeader.toByteArray(Charsets.US_ASCII))
            updateStream.write(csContentBytes)
            updateStream.write("\nendstream\nendobj\n\n".toByteArray(Charsets.US_ASCII))

            // Updated Page object
            val updatedPageOffset = appendPoint + updateStream.size()
            xrefEntries.add(pageObjNum to updatedPageOffset)

            val updatedPageStr = buildUpdatedPageDict(
                pdfText, pageDict, pageObjNum, imgObjNum, contentStreamObjNum
            )
            updateStream.write(updatedPageStr.toByteArray(Charsets.US_ASCII))

            // Cross-reference table + Trailer
            val xrefOffset = appendPoint + updateStream.size()
            val xrefStr = PdfParser.buildXrefAndTrailer(
                xrefEntries, xrefOffset, newSize, trailer.rootObjNum, trailer.prevStartXref
            )
            updateStream.write(xrefStr.toByteArray(Charsets.US_ASCII))

            // Assemble final PDF
            outputFile.outputStream().use { out ->
                out.write(pdfBytes, 0, appendPoint)
                out.write(updateStream.toByteArray())
            }
        } finally {
            deflater.end()
        }
    }

    // MARK: - Private

    /**
     * Build updated page dictionary that adds an image XObject and content stream overlay.
     */
    private fun buildUpdatedPageDict(
        pdfText: String,
        originalDictContent: String,
        pageObjNum: Int,
        imgObjNum: Int,
        contentStreamObjNum: Int
    ): String {
        var dictContent = originalDictContent

        // Handle /Contents — append new content stream reference
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

        // Handle /Resources /XObject — add SigImg reference
        val xobjectMatch = Regex("/XObject\\s*<<([^>]*>>|[^>]*)>>").find(dictContent)
        if (xobjectMatch != null) {
            val fullMatch = xobjectMatch.value
            val insertPos = fullMatch.lastIndexOf(">>")
            val newXObject = fullMatch.substring(0, insertPos) + " /SigImg $imgObjNum 0 R " + fullMatch.substring(insertPos)
            dictContent = dictContent.replaceRange(xobjectMatch.range, newXObject)
        } else {
            val resourcesInlineMatch = Regex("/Resources\\s*<<").find(dictContent)
            val resourcesRefMatch = Regex("/Resources\\s+(\\d+)\\s+(\\d+)\\s+R").find(dictContent)

            if (resourcesInlineMatch != null) {
                val insertPos = resourcesInlineMatch.range.last + 1
                val xobjectStr = " /XObject << /SigImg $imgObjNum 0 R >>"
                dictContent = dictContent.substring(0, insertPos) + xobjectStr + dictContent.substring(insertPos)
            } else if (resourcesRefMatch != null) {
                val resObjNum = resourcesRefMatch.groupValues[1].toInt()
                val resDictContent = PdfParser.findObjectDict(pdfText, resObjNum)
                if (resDictContent != null) {
                    val resXObjectMatch = Regex("/XObject\\s*<<([^>]*>>|[^>]*)>>").find(resDictContent)
                    val newResContent = if (resXObjectMatch != null) {
                        val fullMatch = resXObjectMatch.value
                        val ip = fullMatch.lastIndexOf(">>")
                        val updatedXObj = fullMatch.substring(0, ip) + " /SigImg $imgObjNum 0 R " + fullMatch.substring(ip)
                        resDictContent.replaceRange(resXObjectMatch.range, updatedXObj)
                    } else {
                        "$resDictContent /XObject << /SigImg $imgObjNum 0 R >>"
                    }
                    dictContent = dictContent.replaceRange(
                        resourcesRefMatch.range,
                        "/Resources << $newResContent >>"
                    )
                } else {
                    dictContent += "\n/Resources << /XObject << /SigImg $imgObjNum 0 R >> >>"
                }
            } else {
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
     * Deflate-compress a byte array using the provided Deflater instance.
     */
    private fun deflateCompress(data: ByteArray, deflater: java.util.zip.Deflater): ByteArray {
        deflater.reset()
        deflater.setInput(data)
        deflater.finish()
        val out = java.io.ByteArrayOutputStream(data.size)
        val buffer = ByteArray(8192)
        while (!deflater.finished()) {
            val count = deflater.deflate(buffer)
            out.write(buffer, 0, count)
        }
        return out.toByteArray()
    }
}
