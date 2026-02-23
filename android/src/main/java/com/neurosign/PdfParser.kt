package com.neurosign

/**
 * Low-level PDF structure parser.
 * Extracts trailer info, object dictionaries, page structures, and media boxes
 * from PDF byte arrays using regex-based parsing.
 *
 * Assumes PDF 1.x format with traditional xref tables or xref streams.
 */
internal object PdfParser {

    data class TrailerInfo(
        val rootObjNum: Int,
        val size: Int,
        val prevStartXref: Int
    )

    data class PageInfo(
        val objNum: Int,
        val dictContent: String,
        val existingAnnotRefs: List<String>?
    )

    /**
     * Find the last %%EOF marker in the PDF.
     */
    fun findEOF(bytes: ByteArray): Int? {
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

    /**
     * Parse the PDF trailer to extract /Root object number, /Size, and previous startxref.
     * Handles both traditional xref+trailer and xref stream formats.
     */
    fun parseTrailer(bytes: ByteArray, eofPos: Int): TrailerInfo {
        val text = String(bytes, 0, minOf(eofPos + 10, bytes.size), Charsets.US_ASCII)

        val startxrefIdx = text.lastIndexOf("startxref")
        if (startxrefIdx < 0) throw IllegalStateException("startxref not found")

        val afterStartxref = text.substring(startxrefIdx + "startxref".length).trim()
        val prevStartXref = afterStartxref.split(Regex("\\s+"))[0].toInt()

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
    fun findObjectDict(bytes: ByteArray, objNum: Int): String? {
        return findObjectDict(String(bytes, Charsets.US_ASCII), objNum)
    }

    fun findObjectDict(text: String, objNum: Int): String? {
        val objHeader = "$objNum 0 obj"

        // Find the LAST definition — critical for PDFs with incremental updates
        // where the same object number is redefined in appended sections.
        var objIdx = -1
        var searchFrom = 0
        while (true) {
            val idx = text.indexOf(objHeader, searchFrom)
            if (idx < 0) break
            if (idx == 0 || !text[idx - 1].isDigit()) {
                objIdx = idx  // keep going to find last occurrence
            }
            searchFrom = idx + 1
        }
        if (objIdx < 0) return null

        val afterObj = objIdx + objHeader.length
        val dictStart = text.indexOf("<<", afterObj)
        if (dictStart < 0) return null

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
    fun findFirstPageObjNum(pdfText: String, rootObjNum: Int): Int {
        val rootDict = findObjectDict(pdfText, rootObjNum)
            ?: throw IllegalStateException("Cannot read Root catalog object $rootObjNum")

        val pagesMatch = Regex("/Pages\\s+(\\d+)\\s+\\d+\\s+R").find(rootDict)
            ?: throw IllegalStateException("Cannot find /Pages in catalog")
        val pagesObjNum = pagesMatch.groupValues[1].toInt()

        val pagesDict = findObjectDict(pdfText, pagesObjNum)
            ?: throw IllegalStateException("Cannot read Pages object $pagesObjNum")

        val kidsMatch = Regex("/Kids\\s*\\[\\s*(\\d+)\\s+\\d+\\s+R").find(pagesDict)
            ?: throw IllegalStateException("Cannot find /Kids in Pages")

        return kidsMatch.groupValues[1].toInt()
    }

    /**
     * Read a page's dictionary content and extract existing /Annots references.
     */
    fun readPageInfo(pdfText: String, pageObjNum: Int): PageInfo {
        val dictContent = findObjectDict(pdfText, pageObjNum)
            ?: throw IllegalStateException("Cannot read page object $pageObjNum")

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

    /**
     * Resolve a page object number by 0-based index.
     * Navigates Root -> Pages -> Kids array.
     * Assumes flat page tree (all pages are direct children of root Pages node).
     */
    fun findPageObjNumByIndex(pdfText: String, rootObjNum: Int, pageIndex: Int): Int {
        val rootDict = findObjectDict(pdfText, rootObjNum)
            ?: throw IllegalStateException("Cannot read Root catalog object $rootObjNum")

        val pagesMatch = Regex("/Pages\\s+(\\d+)\\s+\\d+\\s+R").find(rootDict)
            ?: throw IllegalStateException("Cannot find /Pages in catalog")
        val pagesObjNum = pagesMatch.groupValues[1].toInt()

        val pagesDict = findObjectDict(pdfText, pagesObjNum)
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
    fun readPageMediaBox(pdfText: String, pageObjNum: Int): FloatArray {
        val dictContent = findObjectDict(pdfText, pageObjNum)
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

    // MARK: - Byte-level Helpers

    /**
     * Replace a target byte pattern with a replacement of the same length.
     * Throws if the target is not found.
     */
    fun replaceBytes(
        data: ByteArray,
        target: ByteArray,
        replacement: ByteArray,
        searchFrom: Int
    ) {
        require(target.size == replacement.size) { "Target and replacement must be same length" }
        val pos = indexOf(data, target, searchFrom)
        check(pos >= 0) { "Target pattern not found in PDF data (searched from offset $searchFrom)" }
        System.arraycopy(replacement, 0, data, pos, replacement.size)
    }

    /**
     * Find the first occurrence of a byte pattern within data, starting from fromIndex.
     */
    fun indexOf(data: ByteArray, target: ByteArray, fromIndex: Int): Int {
        outer@ for (i in fromIndex..data.size - target.size) {
            for (j in target.indices) {
                if (data[i + j] != target[j]) continue@outer
            }
            return i
        }
        return -1
    }

    /**
     * Calculate the byte offset after %%EOF, skipping trailing newlines.
     */
    fun findAppendPoint(pdfBytes: ByteArray, eofPos: Int): Int {
        var appendPoint = eofPos + "%%EOF".length
        while (appendPoint < pdfBytes.size &&
            (pdfBytes[appendPoint] == '\n'.code.toByte() || pdfBytes[appendPoint] == '\r'.code.toByte())
        ) {
            appendPoint++
        }
        return appendPoint
    }

    /**
     * Escape parentheses in PDF string literals.
     */
    fun escapeParens(str: String): String {
        return str
            .replace("\\", "\\\\")
            .replace("(", "\\(")
            .replace(")", "\\)")
    }

    /**
     * Format a float for PDF output (US locale, 4 decimal places).
     */
    fun formatFloat(value: Float): String {
        return String.format(java.util.Locale.US, "%.4f", value)
    }

    /**
     * Build xref table and trailer for an incremental update.
     */
    fun buildXrefAndTrailer(
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
                sortedEntries[endIdx + 1].first == sortedEntries[endIdx].first + 1
            ) {
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
}
