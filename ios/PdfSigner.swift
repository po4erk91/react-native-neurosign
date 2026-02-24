import Foundation
import Security
import CommonCrypto

// MARK: - Error Types

enum PdfSignerError: Error, LocalizedError {
    case eofNotFound
    case cannotParseTrailer
    case cannotFindFirstPage
    case cannotReadPageInfo
    case cannotReadRootCatalog
    case byteRangePlaceholderNotFound
    case contentsPlaceholderNotFound
    case signatureCreationFailed(String)
    case cmsSignatureTooLarge(actual: Int, max: Int)
    case emptyCertificateChain
    case invalidByteRange
    case invalidDER(String)
    case tsaRequestFailed(String)

    var errorDescription: String? {
        switch self {
        case .eofNotFound: return "Invalid PDF: %%EOF not found"
        case .cannotParseTrailer: return "Cannot parse PDF trailer"
        case .cannotFindFirstPage: return "Cannot find first page"
        case .cannotReadPageInfo: return "Cannot read page info"
        case .cannotReadRootCatalog: return "Cannot read Root catalog"
        case .byteRangePlaceholderNotFound: return "ByteRange placeholder not found in PDF"
        case .contentsPlaceholderNotFound: return "Contents placeholder not found in PDF"
        case .signatureCreationFailed(let msg): return "Failed to create signature: \(msg)"
        case .cmsSignatureTooLarge(let actual, let max): return "CMS signature too large: \(actual) bytes (max \(max))"
        case .emptyCertificateChain: return "Certificate chain is empty"
        case .invalidByteRange: return "ByteRange values exceed PDF data bounds"
        case .invalidDER(let msg): return "Invalid DER structure: \(msg)"
        case .tsaRequestFailed(let msg): return "TSA timestamp request failed: \(msg)"
        }
    }
}

// MARK: - PAdES-B-B PDF Signer

/// PAdES-B-B PDF signer.
/// Implements proper PDF incremental update with AcroForm, SignatureField,
/// Widget Annotation, cross-reference table, and CMS/PKCS#7 container.
enum PdfSigner {

    static let contentsPlaceholderSize = 16384

    // MARK: - PDF Structure Parsing

    struct TrailerInfo {
        let rootObjNum: Int
        let size: Int
        let prevStartXref: Int
    }

    struct PageInfo {
        let objNum: Int
        let dictContent: String
        let existingAnnotRefs: [String]?
    }

    // MARK: - Cached Regex

    private static let refRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"(\d+\s+\d+\s+R)"#)
    }()

    private static let fieldsRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"/Fields\s*\[([^\]]*)\]"#)
    }()

    private static let cachedDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "'D:'yyyyMMddHHmmss'+00''00'''"
        df.timeZone = TimeZone(identifier: "UTC")
        return df
    }()

    // MARK: - Trailer Parsing

    /// Parse the PDF trailer to extract /Root, /Size, and previous startxref.
    static func parseTrailer(in pdfText: String, eofPos: Int) -> TrailerInfo? {
        let text = pdfText

        // Find startxref value
        guard let startxrefRange = text.range(of: "startxref", options: .backwards) else { return nil }
        let afterStartxref = text[startxrefRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = afterStartxref.components(separatedBy: CharacterSet.whitespacesAndNewlines)
        guard !parts.isEmpty, let prevStartXref = Int(parts[0]) else { return nil }

        // Try traditional trailer
        let textBeforeStartxref = String(text[..<startxrefRange.lowerBound])
        if let trailerRange = textBeforeStartxref.range(of: "trailer", options: .backwards) {
            let trailerText = String(textBeforeStartxref[trailerRange.lowerBound...])

            guard let rootMatch = trailerText.range(of: #"/Root\s+(\d+)\s+\d+\s+R"#, options: .regularExpression),
                  let sizeMatch = trailerText.range(of: #"/Size\s+(\d+)"#, options: .regularExpression) else {
                return nil
            }

            let rootStr = String(trailerText[rootMatch])
            let sizeStr = String(trailerText[sizeMatch])
            let rootNum = extractFirstInt(from: rootStr, after: "/Root")
            let sizeNum = extractFirstInt(from: sizeStr, after: "/Size")

            guard let rootObjNum = rootNum, let size = sizeNum else { return nil }

            return TrailerInfo(rootObjNum: rootObjNum, size: size, prevStartXref: prevStartXref)
        }

        // Xref stream: read object at prevStartXref
        let streamEnd = min(prevStartXref + 2000, text.count)
        guard streamEnd > prevStartXref else { return nil }
        let streamStartIdx = text.index(text.startIndex, offsetBy: prevStartXref)
        let streamEndIdx = text.index(text.startIndex, offsetBy: streamEnd)
        let streamObj = String(text[streamStartIdx..<streamEndIdx])

        let rootNum = extractFirstInt(from: streamObj, pattern: #"/Root\s+(\d+)\s+\d+\s+R"#)
        let sizeNum = extractFirstInt(from: streamObj, pattern: #"/Size\s+(\d+)"#)

        guard let rootObjNum = rootNum, let size = sizeNum else { return nil }
        return TrailerInfo(rootObjNum: rootObjNum, size: size, prevStartXref: prevStartXref)
    }

    // MARK: - Object Dict Parsing

    /// Find the dictionary content of a PDF indirect object.
    /// Uses word-boundary check to avoid matching "12 0 obj" when searching for "2 0 obj".
    static func findObjectDict(in pdfText: String, objNum: Int) -> String? {
        let text = pdfText
        let objHeader = "\(objNum) 0 obj"

        // Search for the LAST definition — critical for PDFs with incremental updates
        var searchStart = text.startIndex
        var objRange: Range<String.Index>? = nil
        while let range = text.range(of: objHeader, range: searchStart..<text.endIndex) {
            if range.lowerBound == text.startIndex {
                objRange = range
            } else {
                let charBefore = text[text.index(before: range.lowerBound)]
                if !charBefore.isNumber {
                    objRange = range
                }
            }
            searchStart = range.upperBound
        }
        guard let foundRange = objRange else { return nil }

        let afterObj = String(text[foundRange.upperBound...])
        guard let dictStartIdx = afterObj.range(of: "<<") else { return nil }

        let searchStr = String(afterObj[dictStartIdx.lowerBound...])

        // Track nesting depth
        var depth = 0
        var i = searchStr.startIndex
        while i < searchStr.endIndex {
            let nextIdx = searchStr.index(after: i)
            guard nextIdx < searchStr.endIndex else { break }

            if searchStr[i] == "<" && searchStr[nextIdx] == "<" {
                depth += 1
                i = searchStr.index(after: nextIdx)
            } else if searchStr[i] == ">" && searchStr[nextIdx] == ">" {
                depth -= 1
                if depth == 0 {
                    let contentStart = searchStr.index(searchStr.startIndex, offsetBy: 2)
                    let content = String(searchStr[contentStart..<i]).trimmingCharacters(in: .whitespacesAndNewlines)
                    return content
                }
                i = searchStr.index(after: nextIdx)
            } else {
                i = nextIdx
            }
        }
        return nil
    }

    /// Resolve first page object number from Root -> Pages -> Kids[0].
    static func findFirstPageObjNum(in pdfText: String, rootObjNum: Int) -> Int? {
        guard let rootDict = findObjectDict(in: pdfText, objNum: rootObjNum) else { return nil }
        guard let pagesNum = extractFirstInt(from: rootDict, pattern: #"/Pages\s+(\d+)\s+\d+\s+R"#) else { return nil }
        guard let pagesDict = findObjectDict(in: pdfText, objNum: pagesNum) else { return nil }
        guard let firstPageNum = extractFirstInt(from: pagesDict, pattern: #"/Kids\s*\[\s*(\d+)\s+\d+\s+R"#) else { return nil }
        return firstPageNum
    }

    /// Read page dictionary and extract existing /Annots references.
    static func readPageInfo(in pdfText: String, pageObjNum: Int) -> PageInfo? {
        guard let dictContent = findObjectDict(in: pdfText, objNum: pageObjNum) else { return nil }

        var existingAnnotRefs: [String]? = nil

        if let annotsMatch = dictContent.range(of: #"/Annots\s*\[([^\]]*)\]"#, options: .regularExpression) {
            let annotsStr = String(dictContent[annotsMatch])
            let nsAnnotsStr = annotsStr as NSString
            let refs = refRegex.matches(in: annotsStr, range: NSRange(location: 0, length: nsAnnotsStr.length))
                .map { nsAnnotsStr.substring(with: $0.range) }
            if !refs.isEmpty {
                existingAnnotRefs = refs
            }
        }

        return PageInfo(objNum: pageObjNum, dictContent: dictContent, existingAnnotRefs: existingAnnotRefs)
    }

    // MARK: - Incremental Update Builder

    private struct IncrementalUpdateResult {
        let data: Data
        let contentsHexByteOffset: Int
        let byteRangePlaceholderByteOffset: Int
        let byteRangePlaceholderByteLength: Int
    }

    /// Build a complete PDF incremental update.
    /// Uses UTF-8 byte counting for all offset calculations.
    private static func buildIncrementalUpdate(
        trailer: TrailerInfo,
        pageInfo: PageInfo,
        rootDictContent: String,
        reason: String,
        location: String,
        contactInfo: String,
        appendOffset: Int,
        signatureFieldName: String = "Signature1"
    ) -> IncrementalUpdateResult {
        let sigObjNum = trailer.size
        let fieldObjNum = trailer.size + 1
        let newSize = trailer.size + 2

        let dateStr = cachedDateFormatter.string(from: Date())

        let byteRangePlaceholder = "[0 0000000000 0000000000 0000000000]"
        let contentsPlaceholder = String(repeating: "0", count: contentsPlaceholderSize * 2)

        var xrefEntries: [(objNum: Int, offset: Int)] = []

        // Build body as Data directly to ensure byte-accurate offsets
        var bodyData = Data()

        func appendString(_ s: String) {
            bodyData.append(contentsOf: s.utf8)
        }

        appendString("\n")

        // ── Object 1: Signature Value ──
        let sigObjOffset = appendOffset + bodyData.count
        xrefEntries.append((sigObjNum, sigObjOffset))

        appendString("\(sigObjNum) 0 obj\n")
        appendString("<<\n")
        appendString("/Type /Sig\n")
        appendString("/Filter /Adobe.PPKLite\n")
        appendString("/SubFilter /ETSI.CAdES.detached\n")
        appendString("/ByteRange ")
        let byteRangePlaceholderByteOffset = bodyData.count
        appendString("\(byteRangePlaceholder)\n")

        let contentsLinePrefix = "/Contents "
        appendString(contentsLinePrefix)
        let contentsHexByteOffset = bodyData.count
        appendString("<\(contentsPlaceholder)>\n")

        appendString("/Reason (\(escapePdfString(reason)))\n")
        appendString("/Location (\(escapePdfString(location)))\n")
        appendString("/ContactInfo (\(escapePdfString(contactInfo)))\n")
        appendString("/M (\(dateStr))\n")
        appendString(">>\n")
        appendString("endobj\n\n")

        // ── Object 2: Signature Field + Widget Annotation ──
        let fieldObjOffset = appendOffset + bodyData.count
        xrefEntries.append((fieldObjNum, fieldObjOffset))

        appendString("\(fieldObjNum) 0 obj\n")
        appendString("<<\n")
        appendString("/Type /Annot\n")
        appendString("/Subtype /Widget\n")
        appendString("/FT /Sig\n")
        appendString("/T (\(escapePdfString(signatureFieldName)))\n")
        appendString("/V \(sigObjNum) 0 R\n")
        appendString("/Rect [0 0 0 0]\n")
        appendString("/F 132\n")
        appendString("/P \(pageInfo.objNum) 0 R\n")
        appendString(">>\n")
        appendString("endobj\n\n")

        // ── Object 3: Updated Page ──
        let updatedPageOffset = appendOffset + bodyData.count
        xrefEntries.append((pageInfo.objNum, updatedPageOffset))

        var pageDictClean = pageInfo.dictContent
        if let annotsRange = pageDictClean.range(of: #"/Annots\s*\[[^\]]*\]"#, options: .regularExpression) {
            pageDictClean.removeSubrange(annotsRange)
        }
        pageDictClean = pageDictClean.trimmingCharacters(in: .whitespacesAndNewlines)

        var annotRefs = pageInfo.existingAnnotRefs ?? []
        annotRefs.append("\(fieldObjNum) 0 R")

        appendString("\(pageInfo.objNum) 0 obj\n")
        appendString("<<\n")
        appendString("\(pageDictClean)\n")
        appendString("/Annots [\(annotRefs.joined(separator: " "))]\n")
        appendString(">>\n")
        appendString("endobj\n\n")

        // ── Object 4: Updated Catalog ──
        let updatedCatalogOffset = appendOffset + bodyData.count
        xrefEntries.append((trailer.rootObjNum, updatedCatalogOffset))

        var catalogDictClean = rootDictContent

        // Extract existing /AcroForm /Fields for re-signing
        var existingFields: [String] = []
        if let acroFormRange = catalogDictClean.range(of: "/AcroForm") {
            let afterAcroForm = String(catalogDictClean[acroFormRange.upperBound...]).trimmingCharacters(in: .whitespaces)

            if afterAcroForm.hasPrefix("<<") {
                let nsAfter = afterAcroForm as NSString
                if let fieldsMatch = fieldsRegex.firstMatch(in: afterAcroForm, range: NSRange(location: 0, length: nsAfter.length)) {
                    let fieldsStr = nsAfter.substring(with: fieldsMatch.range(at: 1))
                    let nsFieldsStr = fieldsStr as NSString
                    existingFields = refRegex.matches(in: fieldsStr, range: NSRange(location: 0, length: nsFieldsStr.length))
                        .map { nsFieldsStr.substring(with: $0.range) }
                }

                // Remove the /AcroForm << ... >> from catalog
                var depth = 0
                let searchStr = String(catalogDictClean[acroFormRange.lowerBound...])
                let startPos = catalogDictClean.distance(from: catalogDictClean.startIndex, to: acroFormRange.lowerBound)
                var j = searchStr.startIndex
                while j < searchStr.endIndex {
                    let nextJ = searchStr.index(after: j)
                    guard nextJ < searchStr.endIndex else { break }
                    if searchStr[j] == "<" && searchStr[nextJ] == "<" {
                        depth += 1
                        j = searchStr.index(after: nextJ)
                    } else if searchStr[j] == ">" && searchStr[nextJ] == ">" {
                        depth -= 1
                        if depth == 0 {
                            let endPos = startPos + searchStr.distance(from: searchStr.startIndex, to: searchStr.index(after: nextJ))
                            let removeStart = catalogDictClean.index(catalogDictClean.startIndex, offsetBy: startPos)
                            let removeEnd = catalogDictClean.index(catalogDictClean.startIndex, offsetBy: endPos)
                            catalogDictClean.removeSubrange(removeStart..<removeEnd)
                            break
                        }
                        j = searchStr.index(after: nextJ)
                    } else {
                        j = nextJ
                    }
                }
            } else if afterAcroForm.range(of: #"^\d+\s+\d+\s+R"#, options: .regularExpression) != nil {
                if let fullMatch = catalogDictClean.range(of: #"/AcroForm\s+\d+\s+\d+\s+R"#, options: .regularExpression) {
                    catalogDictClean.removeSubrange(fullMatch)
                }
            }
        }
        catalogDictClean = catalogDictClean.trimmingCharacters(in: .whitespacesAndNewlines)

        var fieldRefs = existingFields
        fieldRefs.append("\(fieldObjNum) 0 R")

        appendString("\(trailer.rootObjNum) 0 obj\n")
        appendString("<<\n")
        appendString("\(catalogDictClean)\n")
        appendString("/AcroForm << /Fields [\(fieldRefs.joined(separator: " "))] /SigFlags 3 >>\n")
        appendString(">>\n")
        appendString("endobj\n\n")

        // ── Cross-reference table ──
        let xrefOffset = appendOffset + bodyData.count

        let sortedEntries = xrefEntries.sorted { $0.objNum < $1.objNum }

        appendString("xref\n")
        var idx = 0
        while idx < sortedEntries.count {
            let startObjNum = sortedEntries[idx].objNum
            var endIdx = idx
            while endIdx + 1 < sortedEntries.count &&
                  sortedEntries[endIdx + 1].objNum == sortedEntries[endIdx].objNum + 1 {
                endIdx += 1
            }
            let count = endIdx - idx + 1
            appendString("\(startObjNum) \(count)\n")
            for k in idx...endIdx {
                appendString(String(format: "%010d 00000 n \n", sortedEntries[k].offset))
            }
            idx = endIdx + 1
        }

        // ── Trailer ──
        appendString("trailer\n")
        appendString("<< /Size \(newSize) /Root \(trailer.rootObjNum) 0 R /Prev \(trailer.prevStartXref) >>\n")
        appendString("startxref\n")
        appendString("\(xrefOffset)\n")
        appendString("%%EOF\n")

        return IncrementalUpdateResult(
            data: bodyData,
            contentsHexByteOffset: contentsHexByteOffset,
            byteRangePlaceholderByteOffset: byteRangePlaceholderByteOffset,
            byteRangePlaceholderByteLength: byteRangePlaceholder.utf8.count
        )
    }

    /// Generate a unique signature field name by checking existing fields.
    static func generateUniqueFieldName(in pdfText: String) -> String {
        var index = 1
        while pdfText.contains("/T (Signature\(index))") {
            index += 1
        }
        return "Signature\(index)"
    }

    // MARK: - Shared signing preparation

    private struct SigningPreparation {
        var fullPdf: Data
        let byteRange: (Int, Int, Int, Int)
        let hash: Data
        let appendPoint: Int
    }

    /// Common preparation logic for both signPdf and prepareForExternalSigning.
    private static func preparePdfForSigning(
        pdfUrl: URL,
        reason: String,
        location: String,
        contactInfo: String,
        outputUrl: URL
    ) throws -> SigningPreparation {
        let pdfData = try Data(contentsOf: pdfUrl)
        guard let pdfText = String(data: pdfData, encoding: .isoLatin1) else {
            throw PdfSignerError.eofNotFound
        }

        guard let eofRange = findEOF(in: pdfData) else {
            throw PdfSignerError.eofNotFound
        }

        guard let trailer = parseTrailer(in: pdfText, eofPos: eofRange.lowerBound) else {
            throw PdfSignerError.cannotParseTrailer
        }

        guard let firstPageNum = findFirstPageObjNum(in: pdfText, rootObjNum: trailer.rootObjNum) else {
            throw PdfSignerError.cannotFindFirstPage
        }

        guard let pageInfo = readPageInfo(in: pdfText, pageObjNum: firstPageNum) else {
            throw PdfSignerError.cannotReadPageInfo
        }

        guard let rootDictContent = findObjectDict(in: pdfText, objNum: trailer.rootObjNum) else {
            throw PdfSignerError.cannotReadRootCatalog
        }

        // Find append point (after %%EOF + newline)
        var appendPoint = eofRange.upperBound
        pdfData.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            while appendPoint < pdfData.count &&
                  (base[appendPoint] == 0x0A || base[appendPoint] == 0x0D) {
                appendPoint += 1
            }
        }

        let fieldName = generateUniqueFieldName(in: pdfText)

        let update = buildIncrementalUpdate(
            trailer: trailer,
            pageInfo: pageInfo,
            rootDictContent: rootDictContent,
            reason: reason,
            location: location,
            contactInfo: contactInfo,
            appendOffset: appendPoint,
            signatureFieldName: fieldName
        )

        // Combine original PDF + incremental update
        var fullPdf = Data(pdfData[0..<appendPoint])
        fullPdf.append(update.data)

        // Calculate ByteRange
        let contentsGapStart = appendPoint + update.contentsHexByteOffset
        let contentsGapEnd = contentsGapStart + 1 + contentsPlaceholderSize * 2 + 1  // < + hex + >
        let byteRange = (0, contentsGapStart, contentsGapEnd, fullPdf.count - contentsGapEnd)

        // Replace ByteRange placeholder (throw on failure instead of silently continuing)
        let byteRangeString = "[\(byteRange.0) \(byteRange.1) \(byteRange.2) \(byteRange.3)]"
        let paddedByteRange = byteRangeString.padding(toLength: update.byteRangePlaceholderByteLength, withPad: " ", startingAt: 0)

        let byteRangePlaceholder = "[0 0000000000 0000000000 0000000000]"
        guard let brRange = findMarker(byteRangePlaceholder, in: fullPdf, near: appendPoint) else {
            throw PdfSignerError.byteRangePlaceholderNotFound
        }
        fullPdf.replaceSubrange(brRange, with: Data(paddedByteRange.utf8))

        // Hash the byte ranges
        let hash = try computeByteRangeHash(pdfData: fullPdf, byteRange: byteRange)

        return SigningPreparation(
            fullPdf: fullPdf,
            byteRange: byteRange,
            hash: hash,
            appendPoint: appendPoint
        )
    }

    // MARK: - Sign PDF

    public static func signPdf(
        pdfUrl: URL,
        identity: CertificateManager.SigningIdentity,
        reason: String,
        location: String,
        contactInfo: String,
        tsaUrl: String? = nil,
        outputUrl: URL
    ) throws {
        var prep = try preparePdfForSigning(
            pdfUrl: pdfUrl,
            reason: reason,
            location: location,
            contactInfo: contactInfo,
            outputUrl: outputUrl
        )

        // Build CMS container (with optional RFC 3161 timestamp for PAdES-B-T)
        let cmsContainer = try buildCMSContainer(
            hash: prep.hash,
            privateKey: identity.privateKey,
            certificate: identity.certificateData,
            certificateChain: identity.certificateChain,
            tsaUrl: tsaUrl
        )

        // Embed CMS into /Contents
        let hexEncoded = cmsContainer.map { String(format: "%02x", $0) }.joined()
        let paddedHex = hexEncoded.padding(toLength: contentsPlaceholderSize * 2, withPad: "0", startingAt: 0)

        let contentsPlaceholder = String(repeating: "0", count: contentsPlaceholderSize * 2)
        guard let contentsRange = findMarker(contentsPlaceholder, in: prep.fullPdf, near: prep.appendPoint) else {
            throw PdfSignerError.contentsPlaceholderNotFound
        }
        prep.fullPdf.replaceSubrange(contentsRange, with: Data(paddedHex.utf8))

        try prep.fullPdf.write(to: outputUrl)
    }

    // MARK: - External Signing

    /// Prepare a PDF for external signing: build incremental update, compute
    /// ByteRange, and return the SHA-256 hash that needs to be signed externally.
    public static func prepareForExternalSigning(
        pdfUrl: URL,
        reason: String,
        location: String,
        contactInfo: String,
        outputUrl: URL
    ) throws -> (hash: Data, hashAlgorithm: String) {
        let prep = try preparePdfForSigning(
            pdfUrl: pdfUrl,
            reason: reason,
            location: location,
            contactInfo: contactInfo,
            outputUrl: outputUrl
        )

        try prep.fullPdf.write(to: outputUrl)
        return (hash: prep.hash, hashAlgorithm: "SHA-256")
    }

    /// Complete external signing by embedding a CMS/PKCS#7 signature into
    /// the prepared PDF's /Contents placeholder.
    public static func completeExternalSigning(
        preparedPdfUrl: URL,
        cmsSignature: Data,
        outputUrl: URL
    ) throws {
        var fullPdf = try Data(contentsOf: preparedPdfUrl)

        let hexEncoded = cmsSignature.map { String(format: "%02x", $0) }.joined()

        guard hexEncoded.count <= contentsPlaceholderSize * 2 else {
            throw PdfSignerError.cmsSignatureTooLarge(actual: cmsSignature.count, max: contentsPlaceholderSize)
        }

        let paddedHex = hexEncoded.padding(toLength: contentsPlaceholderSize * 2, withPad: "0", startingAt: 0)
        let placeholder = String(repeating: "0", count: contentsPlaceholderSize * 2)

        // Search from beginning with wider range for completeExternalSigning
        guard let contentsRange = findMarkerWide(placeholder, in: fullPdf) else {
            throw PdfSignerError.contentsPlaceholderNotFound
        }
        fullPdf.replaceSubrange(contentsRange, with: Data(paddedHex.utf8))

        try fullPdf.write(to: outputUrl)
    }

    // MARK: - Verify Signature

    public struct SignatureInfo {
        public let signerName: String
        public let signedAt: String
        public let valid: Bool
        public let trusted: Bool
        public let reason: String
    }

    public static func verifySignatures(pdfUrl: URL) throws -> [SignatureInfo] {
        let pdfData = try Data(contentsOf: pdfUrl)
        let pdfText = String(data: pdfData, encoding: .isoLatin1) ?? ""
        let signatures = findSignatureDictionaries(in: pdfText)

        return signatures.compactMap { sigInfo -> SignatureInfo? in
            guard let contentsHex = sigInfo.contents,
                  let byteRange = sigInfo.byteRange else {
                return nil
            }

            guard let cmsData = hexToData(contentsHex) else {
                return nil
            }

            // Verify the CMS structure has minimum valid components
            guard cmsData.count > 100 else {
                return SignatureInfo(
                    signerName: sigInfo.name ?? "Unknown",
                    signedAt: sigInfo.date ?? "",
                    valid: false,
                    trusted: false,
                    reason: sigInfo.reason ?? ""
                )
            }

            // Compute the hash from the byte ranges and verify against CMS
            let hashValid: Bool
            if let hash = try? computeByteRangeHash(pdfData: pdfData, byteRange: byteRange) {
                hashValid = verifyCMSDigest(cmsData: cmsData, expectedHash: hash)
            } else {
                hashValid = false
            }

            return SignatureInfo(
                signerName: sigInfo.name ?? "Unknown",
                signedAt: sigInfo.date ?? "",
                valid: hashValid,
                trusted: false,
                reason: sigInfo.reason ?? ""
            )
        }
    }

    /// Verify that the messageDigest attribute in the CMS matches the expected hash.
    private static func verifyCMSDigest(cmsData: Data, expectedHash: Data) -> Bool {
        let bytes = [UInt8](cmsData)
        // Search for the messageDigest OID (1.2.840.113549.1.9.4)
        let messageDigestOid: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x04]

        // Find the OID in the CMS data
        guard let oidOffset = findSequence(messageDigestOid, in: bytes) else {
            return false
        }

        // After the OID, we expect a SET containing an OCTET STRING with the hash
        var pos = oidOffset + messageDigestOid.count
        guard pos < bytes.count else { return false }

        // Skip SET tag and length
        guard bytes[pos] == 0x31 else { return false }
        pos += 1
        guard pos < bytes.count else { return false }
        pos = skipLengthBytes(bytes: bytes, offset: pos)

        // Read OCTET STRING
        guard pos < bytes.count, bytes[pos] == 0x04 else { return false }
        pos += 1
        guard pos < bytes.count else { return false }

        let hashLength: Int
        if bytes[pos] & 0x80 == 0 {
            hashLength = Int(bytes[pos])
            pos += 1
        } else {
            let numLenBytes = Int(bytes[pos] & 0x7F)
            pos += 1
            var len = 0
            for i in 0..<numLenBytes {
                guard pos + i < bytes.count else { return false }
                len = (len << 8) | Int(bytes[pos + i])
            }
            pos += numLenBytes
            hashLength = len
        }

        guard pos + hashLength <= bytes.count else { return false }
        let digestData = Data(bytes[pos..<(pos + hashLength)])
        return digestData == expectedHash
    }

    private static func findSequence(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        for i in 0...(haystack.count - needle.count) {
            if Array(haystack[i..<(i + needle.count)]) == needle {
                return i
            }
        }
        return nil
    }

    private static func skipLengthBytes(bytes: [UInt8], offset: Int) -> Int {
        guard offset < bytes.count else { return offset }
        if bytes[offset] & 0x80 == 0 {
            return offset + 1
        } else {
            let numLenBytes = Int(bytes[offset] & 0x7F)
            return offset + 1 + numLenBytes
        }
    }

    // MARK: - Key Type Detection

    private enum KeyAlgorithm {
        case rsa
        case ecSha256
        case ecSha512

        var secKeyAlgorithm: SecKeyAlgorithm {
            switch self {
            case .rsa:       return .rsaSignatureMessagePKCS1v15SHA256
            case .ecSha256:  return .ecdsaSignatureMessageX962SHA256
            case .ecSha512:  return .ecdsaSignatureMessageX962SHA512
            }
        }

        var signatureAlgorithmOid: [UInt8] {
            switch self {
            case .rsa:       return [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]
            case .ecSha256:  return [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]
            case .ecSha512:  return [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x04]
            }
        }

        var signatureAlgorithmHasNull: Bool {
            switch self {
            case .rsa: return true
            case .ecSha256, .ecSha512: return false
            }
        }
    }

    private static func detectKeyAlgorithm(_ privateKey: SecKey) -> KeyAlgorithm {
        guard let attributes = SecKeyCopyAttributes(privateKey) as? [String: Any],
              let keyType = attributes[kSecAttrKeyType as String] as? String else {
            return .rsa
        }
        if keyType == (kSecAttrKeyTypeECSECPrimeRandom as String) || keyType == (kSecAttrKeyTypeEC as String) {
            let keySize = (attributes[kSecAttrKeySizeInBits as String] as? Int) ?? 256
            return keySize > 384 ? .ecSha512 : .ecSha256
        }
        return .rsa
    }

    // MARK: - Build CMS/PKCS#7 Container

    private static func buildCMSContainer(
        hash: Data,
        privateKey: SecKey,
        certificate: Data,
        certificateChain: [SecCertificate],
        tsaUrl: String? = nil
    ) throws -> Data {
        guard !certificateChain.isEmpty else {
            throw PdfSignerError.emptyCertificateChain
        }

        let keyAlgo = detectKeyAlgorithm(privateKey)

        // Compute SHA-256 hash of the signing certificate for ESSCertIDv2
        let certDER = SecCertificateCopyData(certificateChain[0]) as Data
        var certHash = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        certDER.withUnsafeBytes { certPtr in
            certHash.withUnsafeMutableBytes { hashPtr in
                CC_SHA256(certPtr.baseAddress, CC_LONG(certDER.count),
                          hashPtr.bindMemory(to: UInt8.self).baseAddress)
            }
        }

        let signedAttrsContent = buildSignedAttributesContent(hash: hash, certHash: certHash, certData: certDER)
        let signedAttrs = CMSBuilder.contextTag(0, value: signedAttrsContent)
        let signedAttrsForSigning = CMSBuilder.set(signedAttrsContent)

        var signError: Unmanaged<CFError>?
        let signatureResult = SecKeyCreateSignature(
            privateKey,
            keyAlgo.secKeyAlgorithm,
            signedAttrsForSigning as CFData,
            &signError
        )

        guard let signature = signatureResult as? Data else {
            let error = signError?.takeRetainedValue()
            throw PdfSignerError.signatureCreationFailed(
                error?.localizedDescription ?? "Unknown error"
            )
        }
        // Release CFError if set on success path (unlikely but defensive)
        if signError != nil { _ = signError!.takeRetainedValue() }

        var signedData = Data()

        signedData.append(contentsOf: CMSBuilder.integer(Data([0x01])))

        let sha256Oid: [UInt8] = [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01]
        var digestAlgoSeq = CMSBuilder.oid(sha256Oid)
        digestAlgoSeq.append(contentsOf: CMSBuilder.null())
        let digestAlgos = CMSBuilder.set(CMSBuilder.sequence(digestAlgoSeq))
        signedData.append(contentsOf: digestAlgos)

        let dataOid: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01]
        let encapContent = CMSBuilder.sequence(CMSBuilder.oid(dataOid))
        signedData.append(contentsOf: encapContent)

        var certsData = Data()
        for cert in certificateChain {
            let cd = SecCertificateCopyData(cert) as Data
            certsData.append(cd)
        }
        signedData.append(contentsOf: CMSBuilder.contextTag(0, value: certsData))

        var signerInfo = Data()
        signerInfo.append(contentsOf: CMSBuilder.integer(Data([0x01])))

        let issuerAndSerial = buildIssuerAndSerialNumber(from: certificate)
        signerInfo.append(contentsOf: issuerAndSerial)

        var digestAlgo = CMSBuilder.oid(sha256Oid)
        digestAlgo.append(contentsOf: CMSBuilder.null())
        signerInfo.append(contentsOf: CMSBuilder.sequence(digestAlgo))

        signerInfo.append(contentsOf: signedAttrs)

        var sigAlgo = CMSBuilder.oid(keyAlgo.signatureAlgorithmOid)
        if keyAlgo.signatureAlgorithmHasNull {
            sigAlgo.append(contentsOf: CMSBuilder.null())
        }
        signerInfo.append(contentsOf: CMSBuilder.sequence(sigAlgo))

        signerInfo.append(contentsOf: CMSBuilder.octetString(signature))

        // RFC 3161 timestamp: add id-aa-signatureTimeStampToken as unauthenticated attribute
        if let tsaUrlString = tsaUrl, let tsaURL = URL(string: tsaUrlString) {
            let timestampToken = try requestTimestamp(signature: signature, tsaUrl: tsaURL)
            // OID 1.2.840.113549.1.9.16.2.14 (id-aa-signatureTimeStampToken)
            let tsTokenOid: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x10, 0x02, 0x0E]
            var tsAttr = CMSBuilder.oid(tsTokenOid)
            // The value is a SET containing the raw TimeStampToken (ContentInfo) as-is
            tsAttr.append(contentsOf: CMSBuilder.set(timestampToken))
            let unauthAttrs = CMSBuilder.sequence(tsAttr)
            // [1] IMPLICIT SET OF Attribute
            signerInfo.append(contentsOf: CMSBuilder.contextTag(1, value: unauthAttrs))
        }

        let signerInfoSet = CMSBuilder.set(CMSBuilder.sequence(signerInfo))
        signedData.append(contentsOf: signerInfoSet)

        let signedDataSeq = CMSBuilder.sequence(signedData)

        let signedDataOid: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02]
        var contentInfo = CMSBuilder.oid(signedDataOid)
        contentInfo.append(contentsOf: CMSBuilder.contextTag(0, value: signedDataSeq))

        return CMSBuilder.sequence(contentInfo)
    }

    // MARK: - Signed Attributes (deduplicated)

    /// Build the raw signed attributes content (without wrapper).
    /// Used by both contextTag(0) wrapping (for CMS) and SET wrapping (for signing).
    private static func buildSignedAttributesContent(hash: Data, certHash: Data, certData: Data) -> Data {
        var attrs = Data()

        let contentTypeOid: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x03]
        let dataOid: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01]
        var contentTypeAttr = CMSBuilder.oid(contentTypeOid)
        contentTypeAttr.append(contentsOf: CMSBuilder.set(CMSBuilder.oid(dataOid)))
        attrs.append(contentsOf: CMSBuilder.sequence(contentTypeAttr))

        let messageDigestOid: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x04]
        var digestAttr = CMSBuilder.oid(messageDigestOid)
        digestAttr.append(contentsOf: CMSBuilder.set(CMSBuilder.octetString(hash)))
        attrs.append(contentsOf: CMSBuilder.sequence(digestAttr))

        attrs.append(contentsOf: buildSigningCertV2Attr(certHash: certHash, certData: certData))

        return attrs
    }

    // MARK: - ESSCertIDv2

    private static func buildSigningCertV2Attr(certHash: Data, certData: Data) -> Data {
        let sigCertV2Oid: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x10, 0x02, 0x2F]

        let issuerSerial = buildIssuerSerialFromCert(certData)

        var essCertIdV2Content = CMSBuilder.octetString(certHash)
        essCertIdV2Content.append(contentsOf: issuerSerial)
        let essCertIdV2 = CMSBuilder.sequence(essCertIdV2Content)

        let signingCertV2 = CMSBuilder.sequence(CMSBuilder.sequence(essCertIdV2))

        var attr = CMSBuilder.oid(sigCertV2Oid)
        attr.append(contentsOf: CMSBuilder.set(signingCertV2))
        return CMSBuilder.sequence(attr)
    }

    // MARK: - Issuer and Serial Number (deduplicated)

    /// Navigate DER to extract issuer and serial, used for IssuerSerial with GeneralName wrapping.
    private static func buildIssuerSerialFromCert(_ certData: Data) -> Data {
        let (issuerData, serialData) = extractIssuerAndSerial(from: certData)

        let generalName = CMSBuilder.contextTag(4, value: issuerData)
        let generalNames = CMSBuilder.sequence(generalName)

        var issuerSerialContent = generalNames
        issuerSerialContent.append(contentsOf: serialData)
        return CMSBuilder.sequence(issuerSerialContent)
    }

    /// Navigate DER to extract issuer and serial, used for IssuerAndSerialNumber in SignerInfo.
    private static func buildIssuerAndSerialNumber(from certData: Data) -> Data {
        let (issuerData, serialData) = extractIssuerAndSerial(from: certData)

        var isn = issuerData
        isn.append(serialData)
        return CMSBuilder.sequence(isn)
    }

    /// Common DER navigation to extract issuer and serial number from a certificate.
    private static func extractIssuerAndSerial(from certData: Data) -> (issuer: Data, serial: Data) {
        let bytes = [UInt8](certData)

        guard bytes.count > 10 else {
            return (Data(), Data())
        }

        var pos = skipTagSafe(bytes: bytes, offset: 0) // outer SEQUENCE header
        let tbsContentStart = skipTagSafe(bytes: bytes, offset: pos) // TBS SEQUENCE header
        pos = tbsContentStart

        // Skip version [0] if present
        if pos < bytes.count && bytes[pos] == 0xA0 {
            pos = skipTLVFull(bytes: bytes, offset: pos)
        }

        // Read serialNumber
        let serialStart = pos
        let serialEnd = min(skipTLVFull(bytes: bytes, offset: pos), bytes.count)
        let serialData = Data(bytes[serialStart..<serialEnd])
        pos = serialEnd

        // Skip signature AlgorithmIdentifier
        pos = min(skipTLVFull(bytes: bytes, offset: pos), bytes.count)

        // Read issuer Name
        let issuerStart = pos
        let issuerEnd = min(skipTLVFull(bytes: bytes, offset: pos), bytes.count)
        let issuerData = Data(bytes[issuerStart..<issuerEnd])

        return (issuerData, serialData)
    }

    // MARK: - PDF Helpers

    /// Find %%EOF marker, searching only the last 1024 bytes per PDF spec.
    static func findEOF(in data: Data) -> Range<Int>? {
        let eofMarker = [UInt8]("%%EOF".utf8)
        let searchStart = max(0, data.count - 1024)

        return data.withUnsafeBytes { ptr -> Range<Int>? in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            for i in stride(from: data.count - eofMarker.count, through: searchStart, by: -1) {
                var match = true
                for j in 0..<eofMarker.count {
                    if base[i + j] != eofMarker[j] {
                        match = false
                        break
                    }
                }
                if match {
                    return i..<(i + eofMarker.count)
                }
            }
            return nil
        }
    }

    /// Find a string marker in PDF data near a given offset.
    private static func findMarker(_ marker: String, in data: Data, near offset: Int) -> Range<Int>? {
        let markerBytes = [UInt8](marker.utf8)
        let searchStart = max(0, offset - 100)
        let searchEnd = min(data.count - markerBytes.count, offset + contentsPlaceholderSize * 3)
        guard searchStart < searchEnd else { return nil }

        return data.withUnsafeBytes { ptr -> Range<Int>? in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            for i in searchStart..<searchEnd {
                var match = true
                for j in 0..<markerBytes.count {
                    if base[i + j] != markerBytes[j] {
                        match = false
                        break
                    }
                }
                if match {
                    return i..<(i + markerBytes.count)
                }
            }
            return nil
        }
    }

    /// Find a marker across the entire PDF (used for completeExternalSigning).
    private static func findMarkerWide(_ marker: String, in data: Data) -> Range<Int>? {
        let markerBytes = [UInt8](marker.utf8)
        guard data.count >= markerBytes.count else { return nil }

        return data.withUnsafeBytes { ptr -> Range<Int>? in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            for i in 0...(data.count - markerBytes.count) {
                var match = true
                for j in 0..<markerBytes.count {
                    if base[i + j] != markerBytes[j] {
                        match = false
                        break
                    }
                }
                if match {
                    return i..<(i + markerBytes.count)
                }
            }
            return nil
        }
    }

    /// Escape special characters in PDF string literals.
    /// Handles backslash, parentheses, newline, carriage return, and tab.
    static func escapePdfString(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    // MARK: - Int Extraction Helpers

    static func extractFirstInt(from text: String, after prefix: String) -> Int? {
        guard let prefixRange = text.range(of: prefix) else { return nil }
        let afterPrefix = text[prefixRange.upperBound...].trimmingCharacters(in: .whitespaces)
        let numStr = afterPrefix.prefix(while: { $0.isNumber })
        return Int(numStr)
    }

    static func extractFirstInt(from text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Int(text[range])
    }

    // MARK: - Hash

    private static func computeByteRangeHash(
        pdfData: Data,
        byteRange: (Int, Int, Int, Int)
    ) throws -> Data {
        let range1Start = byteRange.0
        let range1Length = byteRange.1
        let range2Start = byteRange.2
        let range2Length = byteRange.3

        // Validate bounds
        guard range1Start >= 0,
              range1Length >= 0,
              range2Start >= 0,
              range2Length >= 0,
              range1Start + range1Length <= pdfData.count,
              range2Start + range2Length <= pdfData.count else {
            throw PdfSignerError.invalidByteRange
        }

        var hasher = CC_SHA256_CTX()
        CC_SHA256_Init(&hasher)

        if range1Length > 0 {
            pdfData.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                CC_SHA256_Update(&hasher, base.advanced(by: range1Start), CC_LONG(range1Length))
            }
        }

        if range2Length > 0 {
            pdfData.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                CC_SHA256_Update(&hasher, base.advanced(by: range2Start), CC_LONG(range2Length))
            }
        }

        var digest = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        digest.withUnsafeMutableBytes { ptr in
            CC_SHA256_Final(ptr.bindMemory(to: UInt8.self).baseAddress, &hasher)
        }

        return digest
    }

    // MARK: - Signature Verification Parsing

    struct ParsedSignature {
        let contents: String?
        let byteRange: (Int, Int, Int, Int)?
        let name: String?
        let date: String?
        let reason: String?
    }

    static func findSignatureDictionaries(in pdfText: String) -> [ParsedSignature] {
        var results: [ParsedSignature] = []

        var searchRange = pdfText.startIndex..<pdfText.endIndex
        while let range = pdfText.range(of: "/Type /Sig", range: searchRange) {
            let contextStart = pdfText.index(range.lowerBound, offsetBy: -500, limitedBy: pdfText.startIndex) ?? pdfText.startIndex
            let contextEnd = pdfText.index(range.upperBound, offsetBy: contentsPlaceholderSize * 2 + 2000, limitedBy: pdfText.endIndex) ?? pdfText.endIndex
            let context = String(pdfText[contextStart..<contextEnd])

            let byteRange = parseByteRange(from: context)
            let contents = parseContents(from: context)
            let reason = parseField(named: "Reason", from: context)

            results.append(ParsedSignature(
                contents: contents,
                byteRange: byteRange,
                name: nil,
                date: nil,
                reason: reason
            ))

            searchRange = range.upperBound..<pdfText.endIndex
        }

        return results
    }

    static func parseByteRange(from text: String) -> (Int, Int, Int, Int)? {
        guard let match = text.range(of: #"/ByteRange\s*\[\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*\]"#, options: .regularExpression) else {
            return nil
        }
        let str = String(text[match])
        let numbers = str.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .filter { !$0.isEmpty }
            .compactMap { Int($0) }
        guard numbers.count >= 4 else { return nil }
        return (numbers[0], numbers[1], numbers[2], numbers[3])
    }

    static func parseContents(from text: String) -> String? {
        guard let startRange = text.range(of: "/Contents <") else { return nil }
        let afterStart = startRange.upperBound
        guard let endRange = text[afterStart...].range(of: ">") else { return nil }
        return String(text[afterStart..<endRange.lowerBound])
    }

    /// Parse a PDF string field, handling escaped and balanced parentheses.
    static func parseField(named field: String, from text: String) -> String? {
        guard let range = text.range(of: "/\(field) (") else { return nil }
        let afterStart = range.upperBound
        var depth = 1
        var pos = afterStart
        while pos < text.endIndex && depth > 0 {
            let ch = text[pos]
            if ch == "\\" {
                // Skip escaped character
                let next = text.index(after: pos)
                if next < text.endIndex {
                    pos = text.index(after: next)
                    continue
                }
            } else if ch == "(" {
                depth += 1
            } else if ch == ")" {
                depth -= 1
                if depth == 0 {
                    return String(text[afterStart..<pos])
                }
            }
            pos = text.index(after: pos)
        }
        return nil
    }

    static func hexToData(_ hex: String) -> Data? {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
        guard cleaned.count % 2 == 0 else { return nil }

        var data = Data()
        data.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let nextIndex = cleaned.index(index, offsetBy: 2)
            let byteStr = String(cleaned[index..<nextIndex])
            guard let byte = UInt8(byteStr, radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        return data
    }

    // MARK: - DER Parsing Helpers (with bounds checking)

    /// Skip tag + length bytes, returning the offset of the content start.
    private static func skipTagSafe(bytes: [UInt8], offset: Int) -> Int {
        guard offset < bytes.count else { return offset }
        var pos = offset + 1 // skip tag byte
        guard pos < bytes.count else { return pos }

        if bytes[pos] & 0x80 == 0 {
            return pos + 1
        } else {
            let numLenBytes = Int(bytes[pos] & 0x7F)
            guard numLenBytes <= 4 else { return min(pos + 1, bytes.count) }
            return min(pos + 1 + numLenBytes, bytes.count)
        }
    }

    /// Skip an entire TLV (tag + length + value), returning the offset after the value.
    private static func skipTLVFull(bytes: [UInt8], offset: Int) -> Int {
        guard offset < bytes.count else { return offset }
        var pos = offset + 1 // skip tag byte
        guard pos < bytes.count else { return pos }

        var length = 0
        if bytes[pos] & 0x80 == 0 {
            length = Int(bytes[pos])
            pos += 1
        } else {
            let numLenBytes = Int(bytes[pos] & 0x7F)
            guard numLenBytes <= 4 else { return min(pos + 1, bytes.count) }
            pos += 1
            for i in 0..<numLenBytes {
                guard pos + i < bytes.count else { return bytes.count }
                length = (length << 8) | Int(bytes[pos + i])
            }
            pos += numLenBytes
        }

        // Guard against maliciously large length values
        let result = pos + length
        return min(result, bytes.count)
    }
}

// MARK: - RFC 3161 Timestamp

extension PdfSigner {

    /// Request an RFC 3161 timestamp token from a TSA server.
    /// Returns the raw DER-encoded TimeStampToken (a CMS ContentInfo).
    private static func requestTimestamp(signature: Data, tsaUrl: URL) throws -> Data {
        // 1. Hash the signature value with SHA-256
        var sigHash = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        signature.withUnsafeBytes { sigPtr in
            sigHash.withUnsafeMutableBytes { hashPtr in
                CC_SHA256(sigPtr.baseAddress, CC_LONG(signature.count),
                          hashPtr.bindMemory(to: UInt8.self).baseAddress)
            }
        }

        // 2. Build TimeStampReq (RFC 3161 Section 2.4.1)
        let tsaReq = buildTimeStampReq(messageImprint: sigHash)

        // 3. Send HTTP POST to TSA
        let tsaResp = try sendTSARequest(tsaReq, to: tsaUrl)

        // 4. Parse TimeStampResp and extract TimeStampToken
        return try parseTimeStampResp(tsaResp)
    }

    /// Build an ASN.1 DER-encoded TimeStampReq.
    ///
    /// TimeStampReq ::= SEQUENCE {
    ///   version          INTEGER { v1(1) },
    ///   messageImprint   MessageImprint,
    ///   certReq          BOOLEAN DEFAULT FALSE
    /// }
    ///
    /// MessageImprint ::= SEQUENCE {
    ///   hashAlgorithm    AlgorithmIdentifier,
    ///   hashedMessage    OCTET STRING
    /// }
    private static func buildTimeStampReq(messageImprint: Data) -> Data {
        let sha256Oid: [UInt8] = [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01]
        var hashAlgo = CMSBuilder.oid(sha256Oid)
        hashAlgo.append(contentsOf: CMSBuilder.null())
        let hashAlgoSeq = CMSBuilder.sequence(hashAlgo)

        var msgImprint = hashAlgoSeq
        msgImprint.append(contentsOf: CMSBuilder.octetString(messageImprint))
        let msgImprintSeq = CMSBuilder.sequence(msgImprint)

        var reqContent = Data()
        reqContent.append(contentsOf: CMSBuilder.integer(Data([0x01]))) // version 1
        reqContent.append(contentsOf: msgImprintSeq)
        // certReq = TRUE so TSA includes its certificate
        reqContent.append(contentsOf: Data([0x01, 0x01, 0xFF]))

        return CMSBuilder.sequence(reqContent)
    }

    /// Send a TimeStampReq to the TSA via HTTP POST (synchronous).
    private static func sendTSARequest(_ request: Data, to url: URL) throws -> Data {
        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/timestamp-query", forHTTPHeaderField: "Content-Type")
        httpRequest.httpBody = request
        httpRequest.timeoutInterval = 30

        var responseData: Data?
        var responseError: Error?
        let semaphore = DispatchSemaphore(value: 0)

        let task = URLSession.shared.dataTask(with: httpRequest) { data, response, error in
            if let error = error {
                responseError = error
            } else if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                responseError = PdfSignerError.tsaRequestFailed(
                    "TSA returned HTTP \(httpResponse.statusCode)"
                )
            } else {
                responseData = data
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        if let error = responseError {
            throw error
        }
        guard let data = responseData, !data.isEmpty else {
            throw PdfSignerError.tsaRequestFailed("Empty response from TSA")
        }
        return data
    }

    /// Parse a TimeStampResp and extract the TimeStampToken (ContentInfo).
    ///
    /// TimeStampResp ::= SEQUENCE {
    ///   status          PKIStatusInfo,
    ///   timeStampToken  TimeStampToken OPTIONAL
    /// }
    ///
    /// PKIStatusInfo ::= SEQUENCE {
    ///   status    PKIStatus (INTEGER),
    ///   ...
    /// }
    ///
    /// Returns the raw DER bytes of the TimeStampToken ContentInfo.
    private static func parseTimeStampResp(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 4 else {
            throw PdfSignerError.tsaRequestFailed("TSA response too short")
        }

        // Outer SEQUENCE
        guard bytes[0] == 0x30 else {
            throw PdfSignerError.tsaRequestFailed("Invalid TSA response: expected SEQUENCE")
        }
        let (outerContentStart, _) = parseDERLength(bytes, offset: 1)

        // First element: PKIStatusInfo SEQUENCE
        guard outerContentStart < bytes.count, bytes[outerContentStart] == 0x30 else {
            throw PdfSignerError.tsaRequestFailed("Invalid TSA response: expected PKIStatusInfo")
        }
        let (statusSeqContentStart, statusSeqContentLen) = parseDERLength(bytes, offset: outerContentStart + 1)
        let statusSeqEnd = statusSeqContentStart + statusSeqContentLen

        // Read status INTEGER from PKIStatusInfo
        guard statusSeqContentStart < bytes.count, bytes[statusSeqContentStart] == 0x02 else {
            throw PdfSignerError.tsaRequestFailed("Invalid PKIStatusInfo: expected INTEGER")
        }
        let (statusValueStart, statusValueLen) = parseDERLength(bytes, offset: statusSeqContentStart + 1)
        guard statusValueLen > 0 else {
            throw PdfSignerError.tsaRequestFailed("Invalid PKIStatusInfo: empty status")
        }
        let status = Int(bytes[statusValueStart])
        // status 0 = granted, 1 = grantedWithMods — both are acceptable
        guard status == 0 || status == 1 else {
            throw PdfSignerError.tsaRequestFailed("TSA rejected request with status \(status)")
        }

        // Second element: TimeStampToken (starts right after PKIStatusInfo)
        guard statusSeqEnd < bytes.count else {
            throw PdfSignerError.tsaRequestFailed("TSA response missing TimeStampToken")
        }

        // Return the remaining bytes as the TimeStampToken
        return Data(bytes[statusSeqEnd...])
    }

    /// Parse a DER length field starting at `offset`.
    /// Returns (contentStart, contentLength).
    static func parseDERLength(_ bytes: [UInt8], offset: Int) -> (Int, Int) {
        guard offset < bytes.count else { return (offset, 0) }
        let firstByte = bytes[offset]
        if firstByte < 0x80 {
            return (offset + 1, Int(firstByte))
        }
        let numLenBytes = Int(firstByte & 0x7F)
        guard numLenBytes > 0, numLenBytes <= 4 else { return (offset + 1, 0) }
        var length = 0
        for i in 0..<numLenBytes {
            guard offset + 1 + i < bytes.count else { return (offset + 1 + numLenBytes, 0) }
            length = (length << 8) | Int(bytes[offset + 1 + i])
        }
        return (offset + 1 + numLenBytes, length)
    }
}

// MARK: - CMS DER Builder

enum CMSBuilder {
    static func sequence(_ content: Data) -> Data { tag(0x30, content: content) }
    static func set(_ content: Data) -> Data { tag(0x31, content: content) }
    static func integer(_ value: Data) -> Data {
        var intData = value
        if let first = intData.first, first & 0x80 != 0 {
            intData.insert(0x00, at: 0)
        }
        return tag(0x02, content: intData)
    }
    static func octetString(_ value: Data) -> Data { tag(0x04, content: value) }
    static func oid(_ bytes: [UInt8]) -> Data { tag(0x06, content: Data(bytes)) }
    static func null() -> Data { Data([0x05, 0x00]) }
    static func contextTag(_ number: Int, value: Data) -> Data {
        tag(UInt8(0xA0 | (number & 0x1F)), content: value)
    }

    static func tag(_ tagByte: UInt8, content: Data) -> Data {
        var result = Data([tagByte])
        result.append(contentsOf: lengthBytes(content.count))
        result.append(content)
        return result
    }

    static func lengthBytes(_ length: Int) -> [UInt8] {
        if length < 128 { return [UInt8(length)] }
        else if length < 256 { return [0x81, UInt8(length)] }
        else if length < 65536 { return [0x82, UInt8(length >> 8), UInt8(length & 0xFF)] }
        else if length < 16_777_216 { return [0x83, UInt8(length >> 16), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)] }
        else { return [0x84, UInt8(length >> 24), UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)] }
    }
}
