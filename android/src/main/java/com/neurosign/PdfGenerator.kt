package com.neurosign

import java.io.File

/**
 * Generates PDF files from JPEG image data.
 * Writes a proper PDF 1.4 structure with full-resolution JPEG XObjects
 * (avoids Android's PdfDocument which downsamples to 72 DPI).
 *
 * PDF structure:
 *   1 0 obj - Catalog
 *   2 0 obj - Pages
 *   For each page i (0-based):
 *     (3 + i*3) 0 obj - Image XObject (JPEG)
 *     (4 + i*3) 0 obj - Content stream (image placement)
 *     (5 + i*3) 0 obj - Page dictionary
 */
internal object PdfGenerator {

    data class PageData(
        val jpegBytes: ByteArray,
        val imgWidth: Int,
        val imgHeight: Int,
        val pageWidthPt: Float,
        val pageHeightPt: Float,
        val drawX: Float,
        val drawY: Float,
        val drawW: Float,
        val drawH: Float
    )

    /**
     * Write a multi-page PDF with JPEG images at their native resolution.
     */
    fun writePdfWithImages(outputFile: File, pages: List<PageData>) {
        val out = java.io.ByteArrayOutputStream()
        val offsets = mutableMapOf<Int, Int>()
        val ff = { v: Float -> String.format(java.util.Locale.US, "%.4f", v) }

        // Header
        out.write("%PDF-1.4\n%\u00E2\u00E3\u00CF\u00D3\n".toByteArray(Charsets.ISO_8859_1))

        val numPages = pages.size
        val totalObjects = 2 + numPages * 3
        val pageObjNums = (0 until numPages).map { 5 + it * 3 }

        // Write Image XObjects and Content Streams
        for (i in 0 until numPages) {
            val pg = pages[i]
            val imgObjNum = 3 + i * 3
            val csObjNum = 4 + i * 3

            // Image XObject
            offsets[imgObjNum] = out.size()
            val imgHeader = buildString {
                append("$imgObjNum 0 obj\n")
                append("<< /Type /XObject /Subtype /Image\n")
                append("/Width ${pg.imgWidth} /Height ${pg.imgHeight}\n")
                append("/BitsPerComponent 8 /ColorSpace /DeviceRGB\n")
                append("/Filter /DCTDecode /Length ${pg.jpegBytes.size} >>\n")
                append("stream\n")
            }
            out.write(imgHeader.toByteArray(Charsets.US_ASCII))
            out.write(pg.jpegBytes)
            out.write("\nendstream\nendobj\n".toByteArray(Charsets.US_ASCII))

            // Content stream
            val csContent = "q\n${ff(pg.drawW)} 0 0 ${ff(pg.drawH)} ${ff(pg.drawX)} ${ff(pg.drawY)} cm\n/Img Do\nQ\n"
            val csBytes = csContent.toByteArray(Charsets.US_ASCII)

            offsets[csObjNum] = out.size()
            val csHeader = "$csObjNum 0 obj\n<< /Length ${csBytes.size} >>\nstream\n"
            out.write(csHeader.toByteArray(Charsets.US_ASCII))
            out.write(csBytes)
            out.write("\nendstream\nendobj\n".toByteArray(Charsets.US_ASCII))
        }

        // Page objects
        for (i in 0 until numPages) {
            val pg = pages[i]
            val pageObjNum = 5 + i * 3
            val imgObjNum = 3 + i * 3
            val csObjNum = 4 + i * 3

            offsets[pageObjNum] = out.size()
            val pageObj = buildString {
                append("$pageObjNum 0 obj\n")
                append("<< /Type /Page /Parent 2 0 R\n")
                append("/MediaBox [0 0 ${ff(pg.pageWidthPt)} ${ff(pg.pageHeightPt)}]\n")
                append("/Contents $csObjNum 0 R\n")
                append("/Resources << /XObject << /Img $imgObjNum 0 R >> >> >>\n")
                append("endobj\n")
            }
            out.write(pageObj.toByteArray(Charsets.US_ASCII))
        }

        // Pages object
        offsets[2] = out.size()
        val kidsStr = pageObjNums.joinToString(" ") { "$it 0 R" }
        val pagesObj = "2 0 obj\n<< /Type /Pages /Kids [$kidsStr] /Count $numPages >>\nendobj\n"
        out.write(pagesObj.toByteArray(Charsets.US_ASCII))

        // Catalog
        offsets[1] = out.size()
        val catalogObj = "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"
        out.write(catalogObj.toByteArray(Charsets.US_ASCII))

        // Cross-reference table
        val xrefOffset = out.size()
        val xrefSb = StringBuilder()
        xrefSb.append("xref\n")
        xrefSb.append("0 ${totalObjects + 1}\n")
        xrefSb.append("0000000000 65535 f \n")
        for (objNum in 1..totalObjects) {
            val offset = offsets[objNum] ?: 0
            xrefSb.append(String.format("%010d 00000 n \n", offset))
        }

        // Trailer
        xrefSb.append("trailer\n")
        xrefSb.append("<< /Size ${totalObjects + 1} /Root 1 0 R >>\n")
        xrefSb.append("startxref\n")
        xrefSb.append("$xrefOffset\n")
        xrefSb.append("%%EOF\n")
        out.write(xrefSb.toString().toByteArray(Charsets.US_ASCII))

        outputFile.writeBytes(out.toByteArray())
    }
}
