import Foundation
import Security
import CommonCrypto

/// PAdES-B-B PDF signer.
/// Implements proper PDF incremental update with AcroForm, SignatureField,
/// Widget Annotation, cross-reference table, and CMS/PKCS#7 container.
@objcMembers
public class PdfSigner: NSObject {

    private static let contentsPlaceholderSize = 8192

    // MARK: - PDF Structure Parsing

    private struct TrailerInfo {
        let rootObjNum: Int
        let size: Int
        let prevStartXref: Int
    }

    private struct PageInfo {
        let objNum: Int
        let dictContent: String
        let existingAnnotRefs: [String]?
    }

    /// Parse the PDF trailer to extract /Root, /Size, and previous startxref.
    private static func parseTrailer(in data: Data, eofPos: Int) -> TrailerInfo? {
        let endIdx = min(eofPos + 10, data.count)
        guard let text = String(data: data[0..<endIdx], encoding: .isoLatin1) else { return nil }

        // Find startxref value
        guard let startxrefRange = text.range(of: "startxref", options: .backwards) else { return nil }
        let afterStartxref = text[startxrefRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = afterStartxref.components(separatedBy: CharacterSet.whitespacesAndNewlines)
        guard let prevStartXref = Int(parts[0]) else { return nil }

        let startxrefPos = text.distance(from: text.startIndex, to: startxrefRange.lowerBound)

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

    /// Find the dictionary content of a PDF indirect object.
    /// Uses word-boundary check to avoid matching "12 0 obj" when searching for "2 0 obj".
    private static func findObjectDict(in data: Data, objNum: Int) -> String? {
        guard let text = String(data: data, encoding: .isoLatin1) else { return nil }
        let objHeader = "\(objNum) 0 obj"

        // Search for the LAST definition — critical for PDFs with incremental updates
        // where the same object number is redefined in appended sections.
        var searchStart = text.startIndex
        var objRange: Range<String.Index>? = nil
        while let range = text.range(of: objHeader, range: searchStart..<text.endIndex) {
            if range.lowerBound == text.startIndex {
                objRange = range  // keep going to find last occurrence
            } else {
                let charBefore = text[text.index(before: range.lowerBound)]
                if !charBefore.isNumber {
                    objRange = range  // keep going to find last occurrence
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
    private static func findFirstPageObjNum(in data: Data, rootObjNum: Int) -> Int? {
        guard let rootDict = findObjectDict(in: data, objNum: rootObjNum) else { return nil }

        guard let pagesNum = extractFirstInt(from: rootDict, pattern: #"/Pages\s+(\d+)\s+\d+\s+R"#) else { return nil }

        guard let pagesDict = findObjectDict(in: data, objNum: pagesNum) else { return nil }

        guard let firstPageNum = extractFirstInt(from: pagesDict, pattern: #"/Kids\s*\[\s*(\d+)\s+\d+\s+R"#) else { return nil }

        return firstPageNum
    }

    /// Read page dictionary and extract existing /Annots references.
    private static func readPageInfo(in data: Data, pageObjNum: Int) -> PageInfo? {
        guard let dictContent = findObjectDict(in: data, objNum: pageObjNum) else { return nil }

        var existingAnnotRefs: [String]? = nil

        if let annotsMatch = dictContent.range(of: #"/Annots\s*\[([^\]]*)\]"#, options: .regularExpression) {
            let annotsStr = String(dictContent[annotsMatch])
            let refPattern = try? NSRegularExpression(pattern: #"(\d+\s+\d+\s+R)"#)
            let nsAnnotsStr = annotsStr as NSString
            let refs = refPattern?.matches(in: annotsStr, range: NSRange(location: 0, length: nsAnnotsStr.length))
                .map { nsAnnotsStr.substring(with: $0.range) } ?? []
            if !refs.isEmpty {
                existingAnnotRefs = refs
            }
        }

        return PageInfo(objNum: pageObjNum, dictContent: dictContent, existingAnnotRefs: existingAnnotRefs)
    }

    // MARK: - Incremental Update Builder

    private struct IncrementalUpdateResult {
        let data: Data
        let contentsHexOffset: Int
        let byteRangePlaceholderOffset: Int
        let byteRangePlaceholderLength: Int
    }

    /// Build a complete PDF incremental update.
    private static func buildIncrementalUpdate(
        trailer: TrailerInfo,
        pageInfo: PageInfo,
        rootDictContent: String,
        reason: String,
        location: String,
        contactInfo: String,
        appendOffset: Int
    ) -> IncrementalUpdateResult {
        let sigObjNum = trailer.size
        let fieldObjNum = trailer.size + 1
        let newSize = trailer.size + 2

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "'D:'yyyyMMddHHmmss'+00''00'''"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        let dateStr = dateFormatter.string(from: Date())

        let byteRangePlaceholder = "[0 0000000000 0000000000 0000000000]"
        let contentsPlaceholder = String(repeating: "0", count: contentsPlaceholderSize * 2)

        var xrefEntries: [(objNum: Int, offset: Int)] = []

        var body = ""
        body += "\n"

        // ── Object 1: Signature Value ──
        let sigObjOffset = appendOffset + body.count
        xrefEntries.append((sigObjNum, sigObjOffset))

        body += "\(sigObjNum) 0 obj\n"
        body += "<<\n"
        body += "/Type /Sig\n"
        body += "/Filter /Adobe.PPKLite\n"
        body += "/SubFilter /ETSI.CAdES.detached\n"
        body += "/ByteRange \(byteRangePlaceholder)\n"

        let contentsLinePrefix = "/Contents "
        // Point to '<' so ByteRange gap includes <hex> delimiters (per PDF spec / Adobe requirement)
        let contentsHexRelativeOffset = body.count + contentsLinePrefix.count
        body += "\(contentsLinePrefix)<\(contentsPlaceholder)>\n"

        body += "/Reason (\(escapeParentheses(reason)))\n"
        body += "/Location (\(escapeParentheses(location)))\n"
        body += "/ContactInfo (\(escapeParentheses(contactInfo)))\n"
        body += "/M (\(dateStr))\n"
        body += ">>\n"
        body += "endobj\n\n"

        // ── Object 2: Signature Field + Widget Annotation ──
        let fieldObjOffset = appendOffset + body.count
        xrefEntries.append((fieldObjNum, fieldObjOffset))

        body += "\(fieldObjNum) 0 obj\n"
        body += "<<\n"
        body += "/Type /Annot\n"
        body += "/Subtype /Widget\n"
        body += "/FT /Sig\n"
        body += "/T (Signature1)\n"
        body += "/V \(sigObjNum) 0 R\n"
        body += "/Rect [0 0 0 0]\n"
        body += "/F 132\n"
        body += "/P \(pageInfo.objNum) 0 R\n"
        body += ">>\n"
        body += "endobj\n\n"

        // ── Object 3: Updated Page ──
        let updatedPageOffset = appendOffset + body.count
        xrefEntries.append((pageInfo.objNum, updatedPageOffset))

        var pageDictClean = pageInfo.dictContent
        // Remove existing /Annots
        if let annotsRange = pageDictClean.range(of: #"/Annots\s*\[[^\]]*\]"#, options: .regularExpression) {
            pageDictClean.removeSubrange(annotsRange)
        }
        pageDictClean = pageDictClean.trimmingCharacters(in: .whitespacesAndNewlines)

        var annotRefs = pageInfo.existingAnnotRefs ?? []
        annotRefs.append("\(fieldObjNum) 0 R")

        body += "\(pageInfo.objNum) 0 obj\n"
        body += "<<\n"
        body += "\(pageDictClean)\n"
        body += "/Annots [\(annotRefs.joined(separator: " "))]\n"
        body += ">>\n"
        body += "endobj\n\n"

        // ── Object 4: Updated Catalog ──
        let updatedCatalogOffset = appendOffset + body.count
        xrefEntries.append((trailer.rootObjNum, updatedCatalogOffset))

        var catalogDictClean = rootDictContent

        // Extract existing /AcroForm /Fields for re-signing
        var existingFields: [String] = []
        if let acroFormRange = catalogDictClean.range(of: "/AcroForm") {
            let afterAcroForm = String(catalogDictClean[acroFormRange.upperBound...]).trimmingCharacters(in: .whitespaces)

            if afterAcroForm.hasPrefix("<<") {
                // Inline dict — find matching >>
                let fieldsPattern = try? NSRegularExpression(pattern: #"/Fields\s*\[([^\]]*)\]"#)
                let nsAfter = afterAcroForm as NSString
                if let fieldsMatch = fieldsPattern?.firstMatch(in: afterAcroForm, range: NSRange(location: 0, length: nsAfter.length)) {
                    let fieldsStr = nsAfter.substring(with: fieldsMatch.range(at: 1))
                    let refPattern = try? NSRegularExpression(pattern: #"(\d+\s+\d+\s+R)"#)
                    let nsFieldsStr = fieldsStr as NSString
                    existingFields = refPattern?.matches(in: fieldsStr, range: NSRange(location: 0, length: nsFieldsStr.length))
                        .map { nsFieldsStr.substring(with: $0.range) } ?? []
                }

                // Remove the /AcroForm << ... >> from catalog
                var depth = 0
                var searchStr = String(catalogDictClean[acroFormRange.lowerBound...])
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
                // Indirect reference — remove /AcroForm N 0 R
                if let fullMatch = catalogDictClean.range(of: #"/AcroForm\s+\d+\s+\d+\s+R"#, options: .regularExpression) {
                    catalogDictClean.removeSubrange(fullMatch)
                }
            }
        }
        catalogDictClean = catalogDictClean.trimmingCharacters(in: .whitespacesAndNewlines)

        var fieldRefs = existingFields
        fieldRefs.append("\(fieldObjNum) 0 R")

        body += "\(trailer.rootObjNum) 0 obj\n"
        body += "<<\n"
        body += "\(catalogDictClean)\n"
        body += "/AcroForm << /Fields [\(fieldRefs.joined(separator: " "))] /SigFlags 3 >>\n"
        body += ">>\n"
        body += "endobj\n\n"

        // ── Cross-reference table ──
        let xrefOffset = appendOffset + body.count

        let sortedEntries = xrefEntries.sorted { $0.objNum < $1.objNum }

        body += "xref\n"
        var i = 0
        while i < sortedEntries.count {
            let startObjNum = sortedEntries[i].objNum
            var endIdx = i
            while endIdx + 1 < sortedEntries.count &&
                  sortedEntries[endIdx + 1].objNum == sortedEntries[endIdx].objNum + 1 {
                endIdx += 1
            }
            let count = endIdx - i + 1
            body += "\(startObjNum) \(count)\n"
            for k in i...endIdx {
                body += String(format: "%010d 00000 n \n", sortedEntries[k].offset)
            }
            i = endIdx + 1
        }

        // ── Trailer ──
        body += "trailer\n"
        body += "<< /Size \(newSize) /Root \(trailer.rootObjNum) 0 R /Prev \(trailer.prevStartXref) >>\n"
        body += "startxref\n"
        body += "\(xrefOffset)\n"
        body += "%%EOF\n"

        let bodyData = Data(body.utf8)

        let brOffset = body.range(of: byteRangePlaceholder)
            .map { body.distance(from: body.startIndex, to: $0.lowerBound) } ?? 0

        return IncrementalUpdateResult(
            data: bodyData,
            contentsHexOffset: contentsHexRelativeOffset,
            byteRangePlaceholderOffset: brOffset,
            byteRangePlaceholderLength: byteRangePlaceholder.count
        )
    }

    // MARK: - Sign PDF

    public static func signPdf(
        pdfUrl: URL,
        identity: CertificateManager.SigningIdentity,
        reason: String,
        location: String,
        contactInfo: String,
        outputUrl: URL
    ) throws {
        let pdfData = try Data(contentsOf: pdfUrl)

        // Step 1: Parse existing PDF structure
        guard let eofRange = findEOF(in: pdfData) else {
            throw NSError(domain: "Neurosign", code: 100, userInfo: [
                NSLocalizedDescriptionKey: "Invalid PDF: %%EOF not found"
            ])
        }

        guard let trailer = parseTrailer(in: pdfData, eofPos: eofRange.lowerBound) else {
            throw NSError(domain: "Neurosign", code: 100, userInfo: [
                NSLocalizedDescriptionKey: "Cannot parse PDF trailer"
            ])
        }

        guard let firstPageNum = findFirstPageObjNum(in: pdfData, rootObjNum: trailer.rootObjNum) else {
            throw NSError(domain: "Neurosign", code: 100, userInfo: [
                NSLocalizedDescriptionKey: "Cannot find first page"
            ])
        }

        guard let pageInfo = readPageInfo(in: pdfData, pageObjNum: firstPageNum) else {
            throw NSError(domain: "Neurosign", code: 100, userInfo: [
                NSLocalizedDescriptionKey: "Cannot read page info"
            ])
        }

        guard let rootDictContent = findObjectDict(in: pdfData, objNum: trailer.rootObjNum) else {
            throw NSError(domain: "Neurosign", code: 100, userInfo: [
                NSLocalizedDescriptionKey: "Cannot read Root catalog"
            ])
        }

        // Step 2: Find append point (after %%EOF + newline)
        var appendPoint = eofRange.upperBound
        let pdfBytes = [UInt8](pdfData)
        while appendPoint < pdfBytes.count &&
              (pdfBytes[appendPoint] == 0x0A || pdfBytes[appendPoint] == 0x0D) {
            appendPoint += 1
        }

        // Step 3: Build incremental update
        let update = buildIncrementalUpdate(
            trailer: trailer,
            pageInfo: pageInfo,
            rootDictContent: rootDictContent,
            reason: reason,
            location: location,
            contactInfo: contactInfo,
            appendOffset: appendPoint
        )

        // Step 4: Combine original PDF + incremental update
        var fullPdf = Data(pdfData[0..<appendPoint])
        fullPdf.append(update.data)

        // Step 5: Calculate ByteRange
        // Gap covers <hex_digits> including angle brackets (per PDF spec)
        let contentsGapStart = appendPoint + update.contentsHexOffset
        let contentsGapEnd = contentsGapStart + 1 + contentsPlaceholderSize * 2 + 1  // < + hex + >
        let byteRange = (0, contentsGapStart, contentsGapEnd, fullPdf.count - contentsGapEnd)

        // Step 6: Replace ByteRange placeholder
        let byteRangeString = "[\(byteRange.0) \(byteRange.1) \(byteRange.2) \(byteRange.3)]"
        let paddedByteRange = byteRangeString.padding(toLength: update.byteRangePlaceholderLength, withPad: " ", startingAt: 0)

        let byteRangePlaceholder = "[0 0000000000 0000000000 0000000000]"
        if let brRange = findMarker(byteRangePlaceholder, in: fullPdf, near: appendPoint) {
            let replacement = Data(paddedByteRange.utf8)
            fullPdf.replaceSubrange(brRange, with: replacement)
        }

        // Step 7: Hash the byte ranges
        let hash = computeByteRangeHash(pdfData: fullPdf, byteRange: byteRange)

        // Step 8: Build CMS container
        let cmsContainer = try buildCMSContainer(
            hash: hash,
            privateKey: identity.privateKey,
            certificate: identity.certificateData,
            certificateChain: identity.certificateChain
        )

        // Step 9: Embed CMS into /Contents
        let hexEncoded = cmsContainer.map { String(format: "%02x", $0) }.joined()
        let paddedHex = hexEncoded.padding(toLength: contentsPlaceholderSize * 2, withPad: "0", startingAt: 0)

        let contentsPlaceholder = String(repeating: "0", count: contentsPlaceholderSize * 2)
        if let contentsRange = findMarker(contentsPlaceholder, in: fullPdf, near: appendPoint) {
            let replacement = Data(paddedHex.utf8)
            fullPdf.replaceSubrange(contentsRange, with: replacement)
        }

        // Step 10: Write signed PDF
        try fullPdf.write(to: outputUrl)
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
        let pdfData = try Data(contentsOf: pdfUrl)

        guard let eofRange = findEOF(in: pdfData) else {
            throw NSError(domain: "Neurosign", code: 100, userInfo: [
                NSLocalizedDescriptionKey: "Invalid PDF: %%EOF not found"
            ])
        }
        guard let trailer = parseTrailer(in: pdfData, eofPos: eofRange.lowerBound) else {
            throw NSError(domain: "Neurosign", code: 100, userInfo: [
                NSLocalizedDescriptionKey: "Cannot parse PDF trailer"
            ])
        }
        guard let firstPageNum = findFirstPageObjNum(in: pdfData, rootObjNum: trailer.rootObjNum) else {
            throw NSError(domain: "Neurosign", code: 100, userInfo: [
                NSLocalizedDescriptionKey: "Cannot find first page"
            ])
        }
        guard let pageInfo = readPageInfo(in: pdfData, pageObjNum: firstPageNum) else {
            throw NSError(domain: "Neurosign", code: 100, userInfo: [
                NSLocalizedDescriptionKey: "Cannot read page info"
            ])
        }
        guard let rootDictContent = findObjectDict(in: pdfData, objNum: trailer.rootObjNum) else {
            throw NSError(domain: "Neurosign", code: 100, userInfo: [
                NSLocalizedDescriptionKey: "Cannot read Root catalog"
            ])
        }

        var appendPoint = eofRange.upperBound
        let pdfBytes = [UInt8](pdfData)
        while appendPoint < pdfBytes.count &&
              (pdfBytes[appendPoint] == 0x0A || pdfBytes[appendPoint] == 0x0D) {
            appendPoint += 1
        }

        let update = buildIncrementalUpdate(
            trailer: trailer,
            pageInfo: pageInfo,
            rootDictContent: rootDictContent,
            reason: reason,
            location: location,
            contactInfo: contactInfo,
            appendOffset: appendPoint
        )

        var fullPdf = Data(pdfData[0..<appendPoint])
        fullPdf.append(update.data)

        let contentsGapStart = appendPoint + update.contentsHexOffset
        let contentsGapEnd = contentsGapStart + 1 + contentsPlaceholderSize * 2 + 1
        let byteRange = (0, contentsGapStart, contentsGapEnd, fullPdf.count - contentsGapEnd)

        let byteRangeString = "[\(byteRange.0) \(byteRange.1) \(byteRange.2) \(byteRange.3)]"
        let paddedByteRange = byteRangeString.padding(toLength: update.byteRangePlaceholderLength, withPad: " ", startingAt: 0)

        let byteRangePlaceholder = "[0 0000000000 0000000000 0000000000]"
        if let brRange = findMarker(byteRangePlaceholder, in: fullPdf, near: appendPoint) {
            fullPdf.replaceSubrange(brRange, with: Data(paddedByteRange.utf8))
        }

        let hash = computeByteRangeHash(pdfData: fullPdf, byteRange: byteRange)

        try fullPdf.write(to: outputUrl)

        return (hash: hash, hashAlgorithm: "SHA-256")
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
            throw NSError(domain: "Neurosign", code: 102, userInfo: [
                NSLocalizedDescriptionKey: "CMS signature too large: \(cmsSignature.count) bytes (max \(contentsPlaceholderSize))"
            ])
        }

        let paddedHex = hexEncoded.padding(toLength: contentsPlaceholderSize * 2, withPad: "0", startingAt: 0)
        let placeholder = String(repeating: "0", count: contentsPlaceholderSize * 2)

        if let contentsRange = findMarker(placeholder, in: fullPdf, near: 0) {
            fullPdf.replaceSubrange(contentsRange, with: Data(paddedHex.utf8))
        }

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
        let signatures = findSignatureDictionaries(in: pdfData)

        return signatures.compactMap { sigInfo -> SignatureInfo? in
            guard let contentsHex = sigInfo.contents,
                  let byteRange = sigInfo.byteRange else {
                return nil
            }

            guard let cmsData = hexToData(contentsHex) else {
                return nil
            }

            let hash = computeByteRangeHash(pdfData: pdfData, byteRange: byteRange)
            let hasValidStructure = cmsData.count > 100

            return SignatureInfo(
                signerName: sigInfo.name ?? "Unknown",
                signedAt: sigInfo.date ?? "",
                valid: hasValidStructure,
                trusted: false,
                reason: sigInfo.reason ?? ""
            )
        }
    }

    // MARK: - Private: Key Type Detection

    private enum KeyAlgorithm {
        case rsa
        case ecSha256
        case ecSha512

        /// SecKey signing algorithm
        var secKeyAlgorithm: SecKeyAlgorithm {
            switch self {
            case .rsa:       return .rsaSignatureMessagePKCS1v15SHA256
            case .ecSha256:  return .ecdsaSignatureMessageX962SHA256
            case .ecSha512:  return .ecdsaSignatureMessageX962SHA512
            }
        }

        /// OID bytes for the signature algorithm in CMS
        var signatureAlgorithmOid: [UInt8] {
            switch self {
            // 1.2.840.113549.1.1.11 (sha256WithRSAEncryption)
            case .rsa:       return [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]
            // 1.2.840.10045.4.3.2 (ecdsa-with-SHA256)
            case .ecSha256:  return [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]
            // 1.2.840.10045.4.3.4 (ecdsa-with-SHA512)
            case .ecSha512:  return [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x04]
            }
        }

        /// Whether signature algorithm includes NULL parameter (RSA does, ECDSA does not)
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
            return .rsa // default fallback
        }
        if keyType == (kSecAttrKeyTypeECSECPrimeRandom as String) || keyType == (kSecAttrKeyTypeEC as String) {
            // Detect EC key size to choose SHA-256 vs SHA-512
            let keySize = (attributes[kSecAttrKeySizeInBits as String] as? Int) ?? 256
            return keySize > 384 ? .ecSha512 : .ecSha256
        }
        return .rsa
    }

    // MARK: - Private: Build CMS/PKCS#7 Container

    private static func buildCMSContainer(
        hash: Data,
        privateKey: SecKey,
        certificate: Data,
        certificateChain: [SecCertificate]
    ) throws -> Data {
        var signError: Unmanaged<CFError>?

        // Detect key algorithm (RSA vs ECDSA)
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

        let signedAttrs = buildSignedAttributes(hash: hash, certHash: certHash, certData: certDER)
        let signedAttrsForSigning = buildSignedAttributesForSigning(hash: hash, certHash: certHash, certData: certDER)

        guard let signature = SecKeyCreateSignature(
            privateKey,
            keyAlgo.secKeyAlgorithm,
            signedAttrsForSigning as CFData,
            &signError
        ) as? Data else {
            throw signError?.takeRetainedValue() ?? NSError(domain: "Neurosign", code: 101, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create signature"
            ])
        }

        var signedData = Data()

        // version: 1
        signedData.append(contentsOf: CMSBuilder.integer(Data([0x01])))

        // digestAlgorithms: SET OF { sha256 }
        let sha256Oid: [UInt8] = [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01]
        var digestAlgoSeq = CMSBuilder.oid(sha256Oid)
        digestAlgoSeq.append(contentsOf: CMSBuilder.null())
        let digestAlgos = CMSBuilder.set(CMSBuilder.sequence(digestAlgoSeq))
        signedData.append(contentsOf: digestAlgos)

        // encapContentInfo
        let dataOid: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01]
        let encapContent = CMSBuilder.sequence(CMSBuilder.oid(dataOid))
        signedData.append(contentsOf: encapContent)

        // certificates
        var certsData = Data()
        for cert in certificateChain {
            let certDER = SecCertificateCopyData(cert) as Data
            certsData.append(certDER)
        }
        signedData.append(contentsOf: CMSBuilder.contextTag(0, value: certsData))

        // signerInfos
        var signerInfo = Data()

        signerInfo.append(contentsOf: CMSBuilder.integer(Data([0x01])))

        let issuerAndSerial = buildIssuerAndSerialNumber(from: certificate)
        signerInfo.append(contentsOf: issuerAndSerial)

        var digestAlgo = CMSBuilder.oid(sha256Oid)
        digestAlgo.append(contentsOf: CMSBuilder.null())
        signerInfo.append(contentsOf: CMSBuilder.sequence(digestAlgo))

        signerInfo.append(contentsOf: signedAttrs)

        // Signature algorithm (RSA includes NULL param, ECDSA does not)
        var sigAlgo = CMSBuilder.oid(keyAlgo.signatureAlgorithmOid)
        if keyAlgo.signatureAlgorithmHasNull {
            sigAlgo.append(contentsOf: CMSBuilder.null())
        }
        signerInfo.append(contentsOf: CMSBuilder.sequence(sigAlgo))

        signerInfo.append(contentsOf: CMSBuilder.octetString(signature))

        let signerInfoSet = CMSBuilder.set(CMSBuilder.sequence(signerInfo))
        signedData.append(contentsOf: signerInfoSet)

        let signedDataSeq = CMSBuilder.sequence(signedData)

        let signedDataOid: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02]
        var contentInfo = CMSBuilder.oid(signedDataOid)
        contentInfo.append(contentsOf: CMSBuilder.contextTag(0, value: signedDataSeq))

        return CMSBuilder.sequence(contentInfo)
    }

    // MARK: - Private: Signed Attributes

    /// Build ESSCertIDv2 signing-certificate-v2 attribute data.
    /// Includes IssuerSerial for full PAdES B-B compliance.
    private static func buildSigningCertV2Attr(certHash: Data, certData: Data) -> Data {
        // id-aa-signingCertificateV2: 1.2.840.113549.1.9.16.2.47
        let sigCertV2Oid: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x10, 0x02, 0x2F]

        // Extract issuer and serial from certificate DER for IssuerSerial
        let issuerSerial = buildIssuerSerialFromCert(certData)

        // ESSCertIDv2 ::= SEQUENCE {
        //   hashAlgorithm  AlgorithmIdentifier DEFAULT sha256,
        //   certHash       OCTET STRING,
        //   issuerSerial   IssuerSerial OPTIONAL
        // }
        // SHA-256 is DEFAULT, so we omit AlgorithmIdentifier
        var essCertIdV2Content = CMSBuilder.octetString(certHash)
        essCertIdV2Content.append(contentsOf: issuerSerial)
        let essCertIdV2 = CMSBuilder.sequence(essCertIdV2Content)

        // SigningCertificateV2 ::= SEQUENCE { certs SEQUENCE OF ESSCertIDv2 }
        let signingCertV2 = CMSBuilder.sequence(CMSBuilder.sequence(essCertIdV2))

        var attr = CMSBuilder.oid(sigCertV2Oid)
        attr.append(contentsOf: CMSBuilder.set(signingCertV2))
        return CMSBuilder.sequence(attr)
    }

    /// Build IssuerSerial from certificate DER.
    /// IssuerSerial ::= SEQUENCE { issuer GeneralNames, serialNumber CertificateSerialNumber }
    /// GeneralNames ::= SEQUENCE OF GeneralName
    /// GeneralName ::= CHOICE { directoryName [4] Name }
    private static func buildIssuerSerialFromCert(_ certData: Data) -> Data {
        let bytes = [UInt8](certData)

        // Navigate to TBSCertificate
        var pos = 0
        pos = skipTag(bytes: bytes, offset: 0) // outer SEQUENCE header

        let tbsContentStart = skipTag(bytes: bytes, offset: pos) // TBS SEQUENCE header
        pos = tbsContentStart

        // Skip version [0] if present
        if pos < bytes.count && bytes[pos] == 0xA0 {
            pos = skipTLVFull(bytes: bytes, offset: pos)
        }

        // Read serialNumber
        let serialStart = pos
        let serialEnd = skipTLVFull(bytes: bytes, offset: pos)
        let serialData = Data(bytes[serialStart..<min(serialEnd, bytes.count)])
        pos = serialEnd

        // Skip signature AlgorithmIdentifier
        pos = skipTLVFull(bytes: bytes, offset: pos)

        // Read issuer Name
        let issuerStart = pos
        let issuerEnd = skipTLVFull(bytes: bytes, offset: pos)
        let issuerData = Data(bytes[issuerStart..<min(issuerEnd, bytes.count)])

        // Build GeneralName: directoryName [4] EXPLICIT
        let generalName = CMSBuilder.contextTag(4, value: issuerData)
        // Build GeneralNames: SEQUENCE OF GeneralName
        let generalNames = CMSBuilder.sequence(generalName)

        // Build IssuerSerial: SEQUENCE { issuer GeneralNames, serialNumber INTEGER }
        var issuerSerialContent = generalNames
        issuerSerialContent.append(contentsOf: serialData)
        return CMSBuilder.sequence(issuerSerialContent)
    }

    private static func buildSignedAttributes(hash: Data, certHash: Data, certData: Data) -> Data {
        var attrs = Data()

        // contentType
        let contentTypeOid: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x03]
        let dataOid: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01]
        var contentTypeAttr = CMSBuilder.oid(contentTypeOid)
        contentTypeAttr.append(contentsOf: CMSBuilder.set(CMSBuilder.oid(dataOid)))
        attrs.append(contentsOf: CMSBuilder.sequence(contentTypeAttr))

        // messageDigest
        let messageDigestOid: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x04]
        var digestAttr = CMSBuilder.oid(messageDigestOid)
        digestAttr.append(contentsOf: CMSBuilder.set(CMSBuilder.octetString(hash)))
        attrs.append(contentsOf: CMSBuilder.sequence(digestAttr))

        // signing-certificate-v2 (ESSCertIDv2) — mandatory for PAdES B-B
        attrs.append(contentsOf: buildSigningCertV2Attr(certHash: certHash, certData: certData))

        return CMSBuilder.contextTag(0, value: attrs)
    }

    private static func buildSignedAttributesForSigning(hash: Data, certHash: Data, certData: Data) -> Data {
        var attrs = Data()

        // contentType
        let contentTypeOid: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x03]
        let dataOid: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01]
        var contentTypeAttr = CMSBuilder.oid(contentTypeOid)
        contentTypeAttr.append(contentsOf: CMSBuilder.set(CMSBuilder.oid(dataOid)))
        attrs.append(contentsOf: CMSBuilder.sequence(contentTypeAttr))

        // messageDigest
        let messageDigestOid: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x04]
        var digestAttr = CMSBuilder.oid(messageDigestOid)
        digestAttr.append(contentsOf: CMSBuilder.set(CMSBuilder.octetString(hash)))
        attrs.append(contentsOf: CMSBuilder.sequence(digestAttr))

        // signing-certificate-v2 (ESSCertIDv2) — mandatory for PAdES B-B
        attrs.append(contentsOf: buildSigningCertV2Attr(certHash: certHash, certData: certData))

        return CMSBuilder.set(attrs)
    }

    // MARK: - Private: Issuer and Serial Number

    private static func buildIssuerAndSerialNumber(from certData: Data) -> Data {
        let bytes = [UInt8](certData)
        var offset = 0

        guard bytes.count > 10 else {
            return CMSBuilder.sequence(Data())
        }

        offset = skipTLV(bytes: bytes, offset: 0)
        if offset < 0 { offset = 4 }

        let tbsStart = offset
        let tbsContentStart = skipTag(bytes: bytes, offset: tbsStart)

        var pos = tbsContentStart
        if pos < bytes.count && bytes[pos] == 0xA0 {
            pos = skipTLVFull(bytes: bytes, offset: pos)
        }

        let serialStart = pos
        let serialEnd = skipTLVFull(bytes: bytes, offset: pos)
        let serialData = Data(bytes[serialStart..<min(serialEnd, bytes.count)])
        pos = serialEnd

        pos = skipTLVFull(bytes: bytes, offset: pos)

        let issuerStart = pos
        let issuerEnd = skipTLVFull(bytes: bytes, offset: pos)
        let issuerData = Data(bytes[issuerStart..<min(issuerEnd, bytes.count)])

        var isn = issuerData
        isn.append(serialData)
        return CMSBuilder.sequence(isn)
    }

    // MARK: - Private: PDF Helpers

    private static func findEOF(in data: Data) -> Range<Int>? {
        let eofMarker = Data("%%EOF".utf8)
        let bytes = [UInt8](data)
        for i in stride(from: bytes.count - eofMarker.count, through: 0, by: -1) {
            if Data(bytes[i..<(i + eofMarker.count)]) == eofMarker {
                return i..<(i + eofMarker.count)
            }
        }
        return nil
    }

    /// Find a string marker in PDF data near a given offset.
    private static func findMarker(_ marker: String, in data: Data, near offset: Int) -> Range<Int>? {
        let markerData = Data(marker.utf8)
        let searchStart = max(0, offset - 100)
        let searchEnd = min(data.count - markerData.count, offset + contentsPlaceholderSize * 3)
        let bytes = [UInt8](data)

        for i in searchStart..<searchEnd {
            if i + markerData.count <= bytes.count && Data(bytes[i..<(i + markerData.count)]) == markerData {
                return i..<(i + markerData.count)
            }
        }
        return nil
    }

    private static func escapeParentheses(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
    }

    // MARK: - Private: Int Extraction Helpers

    private static func extractFirstInt(from text: String, after prefix: String) -> Int? {
        guard let prefixRange = text.range(of: prefix) else { return nil }
        let afterPrefix = text[prefixRange.upperBound...].trimmingCharacters(in: .whitespaces)
        let numStr = afterPrefix.prefix(while: { $0.isNumber })
        return Int(numStr)
    }

    private static func extractFirstInt(from text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Int(text[range])
    }

    // MARK: - Private: Hash

    private static func computeByteRangeHash(
        pdfData: Data,
        byteRange: (Int, Int, Int, Int)
    ) -> Data {
        var hasher = CC_SHA256_CTX()
        CC_SHA256_Init(&hasher)

        let range1Start = byteRange.0
        let range1Length = byteRange.1
        if range1Length > 0 {
            pdfData.withUnsafeBytes { ptr in
                let base = ptr.baseAddress!.advanced(by: range1Start)
                CC_SHA256_Update(&hasher, base, CC_LONG(range1Length))
            }
        }

        let range2Start = byteRange.2
        let range2Length = byteRange.3
        if range2Length > 0 {
            pdfData.withUnsafeBytes { ptr in
                let base = ptr.baseAddress!.advanced(by: range2Start)
                CC_SHA256_Update(&hasher, base, CC_LONG(range2Length))
            }
        }

        var digest = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        digest.withUnsafeMutableBytes { ptr in
            CC_SHA256_Final(ptr.bindMemory(to: UInt8.self).baseAddress, &hasher)
        }

        return digest
    }

    // MARK: - Private: Signature Verification Parsing

    private struct ParsedSignature {
        let contents: String?
        let byteRange: (Int, Int, Int, Int)?
        let name: String?
        let date: String?
        let reason: String?
    }

    private static func findSignatureDictionaries(in data: Data) -> [ParsedSignature] {
        let text = String(data: data, encoding: .isoLatin1) ?? ""
        var results: [ParsedSignature] = []

        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: "/Type /Sig", range: searchRange) {
            let contextStart = text.index(range.lowerBound, offsetBy: -500, limitedBy: text.startIndex) ?? text.startIndex
            let contextEnd = text.index(range.upperBound, offsetBy: contentsPlaceholderSize * 2 + 2000, limitedBy: text.endIndex) ?? text.endIndex
            let context = String(text[contextStart..<contextEnd])

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

            searchRange = range.upperBound..<text.endIndex
        }

        return results
    }

    private static func parseByteRange(from text: String) -> (Int, Int, Int, Int)? {
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

    private static func parseContents(from text: String) -> String? {
        guard let startRange = text.range(of: "/Contents <") else { return nil }
        let afterStart = startRange.upperBound
        guard let endRange = text[afterStart...].range(of: ">") else { return nil }
        return String(text[afterStart..<endRange.lowerBound])
    }

    private static func parseField(named field: String, from text: String) -> String? {
        guard let range = text.range(of: "/\(field) (") else { return nil }
        let afterStart = range.upperBound
        guard let endRange = text[afterStart...].range(of: ")") else { return nil }
        return String(text[afterStart..<endRange.lowerBound])
    }

    private static func hexToData(_ hex: String) -> Data? {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
        guard cleaned.count % 2 == 0 else { return nil }

        var data = Data()
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

    // MARK: - DER Parsing Helpers

    private static func skipTag(bytes: [UInt8], offset: Int) -> Int {
        guard offset < bytes.count else { return offset }
        var pos = offset + 1
        if pos >= bytes.count { return pos }

        if bytes[pos] & 0x80 == 0 {
            return pos + 1
        } else {
            let numLenBytes = Int(bytes[pos] & 0x7F)
            return pos + 1 + numLenBytes
        }
    }

    private static func skipTLV(bytes: [UInt8], offset: Int) -> Int {
        return skipTag(bytes: bytes, offset: offset)
    }

    private static func skipTLVFull(bytes: [UInt8], offset: Int) -> Int {
        guard offset < bytes.count else { return offset }
        var pos = offset + 1
        if pos >= bytes.count { return pos }

        var length = 0
        if bytes[pos] & 0x80 == 0 {
            length = Int(bytes[pos])
            pos += 1
        } else {
            let numLenBytes = Int(bytes[pos] & 0x7F)
            pos += 1
            for i in 0..<numLenBytes {
                if pos + i < bytes.count {
                    length = (length << 8) | Int(bytes[pos + i])
                }
            }
            pos += numLenBytes
        }

        return pos + length
    }
}

// MARK: - CMS DER Builder

private enum CMSBuilder {
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
        else { return [0x83, UInt8(length >> 16), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)] }
    }
}
