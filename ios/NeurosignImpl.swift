import Foundation
import UIKit

public typealias RNResolver = @convention(block) (Any?) -> Void
public typealias RNRejecter = @convention(block) (String?, String?, Error?) -> Void

@objcMembers
public class NeurosignImpl: NSObject {

    private let fileManager = FileManager.default

    // MARK: - Temp Directory (lazy, thread-safe)

    private lazy var tempDirectory: URL = {
        let dir = fileManager.temporaryDirectory.appendingPathComponent("neurosign", isDirectory: true)
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            NSLog("[Neurosign] Failed to create temp directory: %@", error.localizedDescription)
        }
        return dir
    }()

    // MARK: - Page Size Constants

    private func pageSizeForName(_ name: String) -> CGSize {
        switch name.uppercased() {
        case "A4":
            return CGSize(width: 595.28, height: 841.89)
        case "LETTER":
            return CGSize(width: 612, height: 792)
        default:
            return CGSize(width: 595.28, height: 841.89)
        }
    }

    // MARK: - URL Resolution

    private func resolveFileUrl(_ urlString: String) -> URL? {
        if let url = URL(string: urlString), url.isFileURL {
            return url
        }
        if urlString.hasPrefix("/") {
            return URL(fileURLWithPath: urlString)
        }
        if urlString.hasPrefix("file://") {
            let path = String(urlString.dropFirst("file://".count))
            return URL(fileURLWithPath: path)
        }
        return URL(string: urlString)
    }

    // MARK: - generatePdf

    public func generatePdf(
        imageUrls: [String],
        fileName: String,
        pageSize: String,
        pageMargin: Double,
        quality: Double,
        resolver: @escaping RNResolver,
        rejecter: @escaping RNRejecter
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                rejecter("INTERNAL_ERROR", "Module deallocated", nil)
                return
            }

            guard !imageUrls.isEmpty else {
                rejecter("INVALID_INPUT", "imageUrls array must not be empty", nil)
                return
            }

            let margin = CGFloat(pageMargin)
            let targetPageSize = self.pageSizeForName(pageSize)
            let jpegQuality = CGFloat(min(max(quality, 0), 100) / 100.0)

            do {
                // Collect page data: JPEG bytes + layout info
                struct PageInfo {
                    let jpegData: Data
                    let imgWidth: Int
                    let imgHeight: Int
                    let pageWidth: CGFloat
                    let pageHeight: CGFloat
                    let drawX: CGFloat
                    let drawY: CGFloat
                    let drawW: CGFloat
                    let drawH: CGFloat
                }

                var pages: [PageInfo] = []

                for urlString in imageUrls {
                    autoreleasepool {
                        guard let image = self.loadImage(from: urlString) else { return }

                        let imgPixelW = Int(image.size.width * image.scale)
                        let imgPixelH = Int(image.size.height * image.scale)

                        let pageW: CGFloat
                        let pageH: CGFloat
                        let drawRect: CGRect

                        if pageSize.uppercased() == "ORIGINAL" {
                            pageW = image.size.width + margin * 2
                            pageH = image.size.height + margin * 2
                            drawRect = CGRect(x: margin, y: margin, width: image.size.width, height: image.size.height)
                        } else {
                            pageW = targetPageSize.width
                            pageH = targetPageSize.height
                            let drawableW = pageW - margin * 2
                            let drawableH = pageH - margin * 2
                            drawRect = self.aspectFitRect(
                                for: image.size,
                                in: CGSize(width: drawableW, height: drawableH),
                                origin: CGPoint(x: margin, y: margin)
                            )
                        }

                        // Downsample if image is much larger than needed
                        let targetPixelW = drawRect.width * 2  // 2x for good quality
                        let targetPixelH = drawRect.height * 2
                        let workingImage: UIImage
                        if CGFloat(imgPixelW) > targetPixelW || CGFloat(imgPixelH) > targetPixelH {
                            let ratio = min(targetPixelW / CGFloat(imgPixelW), targetPixelH / CGFloat(imgPixelH))
                            let newSize = CGSize(width: floor(CGFloat(imgPixelW) * ratio), height: floor(CGFloat(imgPixelH) * ratio))
                            // Force scale=1 so renderer uses exact pixel dimensions (not screen scale)
                            let fmt = UIGraphicsImageRendererFormat()
                            fmt.scale = 1.0
                            let renderer = UIGraphicsImageRenderer(size: newSize, format: fmt)
                            workingImage = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
                        } else {
                            workingImage = image
                        }

                        guard let jpeg = workingImage.jpegData(compressionQuality: jpegQuality) else { return }

                        // Get actual pixel dimensions of the JPEG we just created
                        let finalW: Int
                        let finalH: Int
                        if workingImage !== image {
                            finalW = Int(workingImage.size.width * workingImage.scale)
                            finalH = Int(workingImage.size.height * workingImage.scale)
                        } else {
                            finalW = imgPixelW
                            finalH = imgPixelH
                        }

                        pages.append(PageInfo(
                            jpegData: jpeg,
                            imgWidth: finalW,
                            imgHeight: finalH,
                            pageWidth: pageW,
                            pageHeight: pageH,
                            drawX: drawRect.origin.x,
                            // PDF Y-axis is bottom-up
                            drawY: pageH - drawRect.origin.y - drawRect.height,
                            drawW: drawRect.width,
                            drawH: drawRect.height
                        ))
                    }
                }

                guard !pages.isEmpty else {
                    rejecter("PDF_GENERATION_FAILED", "No images could be loaded from the provided URLs", nil)
                    return
                }

                // Build PDF with raw JPEG streams (DCTDecode) — same approach as Android
                let pdfData = self.buildPdfWithJpegStreams(pages: pages.map { p in
                    (jpegData: p.jpegData, imgWidth: p.imgWidth, imgHeight: p.imgHeight,
                     pageWidth: p.pageWidth, pageHeight: p.pageHeight,
                     drawX: p.drawX, drawY: p.drawY, drawW: p.drawW, drawH: p.drawH)
                })

                let outputFileName = fileName.hasSuffix(".pdf") ? fileName : "\(fileName).pdf"
                let outputUrl = self.tempDirectory.appendingPathComponent(
                    "\(UUID().uuidString)_\(outputFileName)"
                )
                try pdfData.write(to: outputUrl)

                resolver([
                    "pdfUrl": outputUrl.absoluteString,
                    "pageCount": pages.count,
                    "fileSize": pdfData.count,
                ] as [String: Any])
            } catch {
                rejecter("PDF_GENERATION_FAILED", error.localizedDescription, error)
            }
        }
    }

    /// Build a PDF file with raw JPEG image streams using /DCTDecode filter.
    /// This avoids UIGraphicsPDFRenderer which re-encodes images as uncompressed bitmaps.
    ///
    /// PDF structure (same as Android PdfGenerator):
    ///   1 0 obj - Catalog
    ///   2 0 obj - Pages
    ///   Per page i (0-based):
    ///     (3+i*3) - Image XObject (JPEG)
    ///     (4+i*3) - Content stream
    ///     (5+i*3) - Page dictionary
    private func buildPdfWithJpegStreams(
        pages: [(jpegData: Data, imgWidth: Int, imgHeight: Int,
                 pageWidth: CGFloat, pageHeight: CGFloat,
                 drawX: CGFloat, drawY: CGFloat, drawW: CGFloat, drawH: CGFloat)]
    ) -> Data {
        var out = Data()
        var offsets = [Int: Int]()
        let numPages = pages.count
        let totalObjects = 2 + numPages * 3

        func ff(_ v: CGFloat) -> String { String(format: "%.4f", v) }
        func append(_ str: String) { out.append(str.data(using: .isoLatin1)!) }

        // Header
        append("%PDF-1.4\n%\u{E2}\u{E3}\u{CF}\u{D3}\n")

        // Write image XObjects and content streams
        for i in 0..<numPages {
            let pg = pages[i]
            let imgObjNum = 3 + i * 3
            let csObjNum = 4 + i * 3

            // Image XObject with raw JPEG data
            offsets[imgObjNum] = out.count
            append("\(imgObjNum) 0 obj\n")
            append("<< /Type /XObject /Subtype /Image\n")
            append("/Width \(pg.imgWidth) /Height \(pg.imgHeight)\n")
            append("/BitsPerComponent 8 /ColorSpace /DeviceRGB\n")
            append("/Filter /DCTDecode /Length \(pg.jpegData.count) >>\n")
            append("stream\n")
            out.append(pg.jpegData)
            append("\nendstream\nendobj\n")

            // Content stream — place image on page
            let csContent = "q\n\(ff(pg.drawW)) 0 0 \(ff(pg.drawH)) \(ff(pg.drawX)) \(ff(pg.drawY)) cm\n/Img Do\nQ\n"
            let csBytes = csContent.data(using: .ascii)!
            offsets[csObjNum] = out.count
            append("\(csObjNum) 0 obj\n<< /Length \(csBytes.count) >>\nstream\n")
            out.append(csBytes)
            append("\nendstream\nendobj\n")
        }

        // Page objects
        for i in 0..<numPages {
            let pg = pages[i]
            let pageObjNum = 5 + i * 3
            let imgObjNum = 3 + i * 3
            let csObjNum = 4 + i * 3

            offsets[pageObjNum] = out.count
            append("\(pageObjNum) 0 obj\n")
            append("<< /Type /Page /Parent 2 0 R\n")
            append("/MediaBox [0 0 \(ff(pg.pageWidth)) \(ff(pg.pageHeight))]\n")
            append("/Contents \(csObjNum) 0 R\n")
            append("/Resources << /XObject << /Img \(imgObjNum) 0 R >> >> >>\n")
            append("endobj\n")
        }

        // Pages object
        let pageObjNums = (0..<numPages).map { 5 + $0 * 3 }
        let kidsStr = pageObjNums.map { "\($0) 0 R" }.joined(separator: " ")
        offsets[2] = out.count
        append("2 0 obj\n<< /Type /Pages /Kids [\(kidsStr)] /Count \(numPages) >>\nendobj\n")

        // Catalog
        offsets[1] = out.count
        append("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")

        // Cross-reference table
        let xrefOffset = out.count
        append("xref\n")
        append("0 \(totalObjects + 1)\n")
        append("0000000000 65535 f \n")
        for objNum in 1...totalObjects {
            let offset = offsets[objNum] ?? 0
            append(String(format: "%010d 00000 n \n", offset))
        }

        // Trailer
        append("trailer\n")
        append("<< /Size \(totalObjects + 1) /Root 1 0 R >>\n")
        append("startxref\n")
        append("\(xrefOffset)\n")
        append("%%EOF\n")

        return out
    }

    // MARK: - addSignatureImage

    public func addSignatureImage(
        pdfUrl: String,
        signatureImageUrl: String,
        placements: [[String: Any]],
        resolver: @escaping RNResolver,
        rejecter: @escaping RNRejecter
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                rejecter("INTERNAL_ERROR", "Module deallocated", nil)
                return
            }

            guard let pdfFileUrl = self.resolveFileUrl(pdfUrl),
                  let pdfDocument = CGPDFDocument(pdfFileUrl as CFURL) else {
                rejecter("INVALID_INPUT", "Cannot open PDF at: \(pdfUrl)", nil)
                return
            }

            guard let signatureImage = self.loadImage(from: signatureImageUrl) else {
                rejecter("INVALID_INPUT", "Cannot load signature image at: \(signatureImageUrl)", nil)
                return
            }

            let totalPages = pdfDocument.numberOfPages

            // Build lookup: pageIndex -> placement
            var placementMap = [Int: (x: Double, y: Double, width: Double, height: Double)]()
            for p in placements {
                guard let pi = p["pageIndex"] as? NSNumber,
                      let px = p["x"] as? NSNumber,
                      let py = p["y"] as? NSNumber,
                      let pw = p["width"] as? NSNumber,
                      let ph = p["height"] as? NSNumber else { continue }
                let pageIdx = pi.intValue
                guard pageIdx >= 0, pageIdx < totalPages else {
                    rejecter("INVALID_INPUT", "pageIndex \(pageIdx) out of range (0..\(totalPages - 1))", nil)
                    return
                }
                placementMap[pageIdx] = (x: px.doubleValue, y: py.doubleValue, width: pw.doubleValue, height: ph.doubleValue)
            }

            guard !placementMap.isEmpty else {
                rejecter("INVALID_INPUT", "No valid placements provided", nil)
                return
            }

            do {
                let outputUrl = self.tempDirectory.appendingPathComponent(
                    "\(UUID().uuidString)_visual.pdf"
                )

                let firstPage = pdfDocument.page(at: 1)
                let firstPageBox = firstPage?.getBoxRect(.mediaBox) ?? CGRect(x: 0, y: 0, width: 595.28, height: 841.89)

                let format = UIGraphicsPDFRendererFormat()
                let renderer = UIGraphicsPDFRenderer(
                    bounds: firstPageBox,
                    format: format
                )

                let resultData = renderer.pdfData { context in
                    for i in 1...totalPages {
                        guard let page = pdfDocument.page(at: i) else { continue }
                        let pageBox = page.getBoxRect(.mediaBox)

                        context.beginPage(withBounds: pageBox, pageInfo: [:])

                        let cgContext = context.cgContext
                        cgContext.translateBy(x: 0, y: pageBox.height)
                        cgContext.scaleBy(x: 1, y: -1)
                        cgContext.drawPDFPage(page)

                        if let placement = placementMap[i - 1] {
                            cgContext.scaleBy(x: 1, y: -1)
                            cgContext.translateBy(x: 0, y: -pageBox.height)

                            let sigRect = CGRect(
                                x: CGFloat(placement.x) * pageBox.width,
                                y: CGFloat(placement.y) * pageBox.height,
                                width: CGFloat(placement.width) * pageBox.width,
                                height: CGFloat(placement.height) * pageBox.height
                            )
                            signatureImage.draw(in: sigRect)
                        }
                    }
                }

                try resultData.write(to: outputUrl)

                resolver([
                    "pdfUrl": outputUrl.absoluteString,
                ] as [String: Any])
            } catch {
                rejecter("PDF_GENERATION_FAILED", error.localizedDescription, error)
            }
        }
    }

    // MARK: - renderPdfPage

    public func renderPdfPage(
        pdfUrl: String,
        pageIndex: Int,
        width: Double,
        height: Double,
        resolver: @escaping RNResolver,
        rejecter: @escaping RNRejecter
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                rejecter("INTERNAL_ERROR", "Module deallocated", nil)
                return
            }

            guard let pdfFileUrl = self.resolveFileUrl(pdfUrl),
                  let pdfDocument = CGPDFDocument(pdfFileUrl as CFURL) else {
                rejecter("INVALID_INPUT", "Cannot open PDF at: \(pdfUrl)", nil)
                return
            }

            let totalPages = pdfDocument.numberOfPages

            guard pageIndex >= 0, pageIndex < totalPages else {
                rejecter("INVALID_INPUT", "pageIndex \(pageIndex) out of range (0..\(totalPages - 1))", nil)
                return
            }

            guard let page = pdfDocument.page(at: pageIndex + 1) else {
                rejecter("PDF_GENERATION_FAILED", "Cannot get page \(pageIndex)", nil)
                return
            }

            let mediaBox = page.getBoxRect(.mediaBox)
            let targetSize = CGSize(width: CGFloat(width), height: CGFloat(height))

            let scaleX = targetSize.width / mediaBox.width
            let scaleY = targetSize.height / mediaBox.height
            let scale = min(scaleX, scaleY)

            let renderWidth = mediaBox.width * scale
            let renderHeight = mediaBox.height * scale
            let renderSize = CGSize(width: renderWidth, height: renderHeight)

            let renderer = UIGraphicsImageRenderer(size: renderSize)
            let image = renderer.image { ctx in
                let cgContext = ctx.cgContext
                cgContext.setFillColor(UIColor.white.cgColor)
                cgContext.fill(CGRect(origin: .zero, size: renderSize))
                cgContext.translateBy(x: 0, y: renderHeight)
                cgContext.scaleBy(x: scale, y: -scale)
                cgContext.drawPDFPage(page)
            }

            guard let pngData = image.pngData() else {
                rejecter("PDF_GENERATION_FAILED", "Cannot render page to PNG", nil)
                return
            }

            do {
                let outputUrl = self.tempDirectory.appendingPathComponent(
                    "page_\(pageIndex)_\(UUID().uuidString).png"
                )
                try pngData.write(to: outputUrl)

                resolver([
                    "imageUrl": outputUrl.absoluteString,
                    "pageWidth": mediaBox.width,
                    "pageHeight": mediaBox.height,
                    "pageCount": totalPages,
                ] as [String: Any])
            } catch {
                rejecter("PDF_GENERATION_FAILED", error.localizedDescription, error)
            }
        }
    }

    // MARK: - signPdf

    public func signPdf(
        pdfUrl: String,
        certificateType: String,
        certificatePath: String?,
        certificatePassword: String?,
        keychainAlias: String?,
        reason: String,
        location: String,
        contactInfo: String,
        tsaUrl: String?,
        resolver: @escaping RNResolver,
        rejecter: @escaping RNRejecter
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                rejecter("INTERNAL_ERROR", "Module deallocated", nil)
                return
            }

            do {
                let identity: CertificateManager.SigningIdentity
                var tempCertAlias: String? = nil

                switch certificateType {
                case "p12":
                    guard let path = certificatePath, let password = certificatePassword else {
                        rejecter("INVALID_INPUT", "certificatePath and certificatePassword required for p12 type", nil)
                        return
                    }
                    identity = try CertificateManager.getSigningIdentityFromP12(filePath: path, password: password)

                case "keychain":
                    guard let alias = keychainAlias else {
                        rejecter("INVALID_INPUT", "keychainAlias required for keychain type", nil)
                        return
                    }
                    identity = try CertificateManager.getSigningIdentity(alias: alias)

                case "selfSigned":
                    let alias = "temp_selfsigned_\(UUID().uuidString.prefix(8))"
                    tempCertAlias = alias
                    _ = try CertificateManager.generateSelfSigned(
                        commonName: "Neurosign User",
                        organization: "",
                        country: "",
                        validityDays: 365,
                        alias: alias
                    )
                    identity = try CertificateManager.getSigningIdentity(alias: alias)

                default:
                    rejecter("INVALID_INPUT", "Unknown certificateType: \(certificateType)", nil)
                    return
                }

                guard let pdfFileUrl = self.resolveFileUrl(pdfUrl) else {
                    rejecter("INVALID_INPUT", "Invalid PDF URL: \(pdfUrl)", nil)
                    return
                }

                let outputUrl = self.tempDirectory.appendingPathComponent(
                    "\(UUID().uuidString)_signed.pdf"
                )

                try PdfSigner.signPdf(
                    pdfUrl: pdfFileUrl,
                    identity: identity,
                    reason: reason,
                    location: location,
                    contactInfo: contactInfo,
                    tsaUrl: tsaUrl,
                    outputUrl: outputUrl
                )

                // Clean up temp self-signed certificate from Keychain
                if let alias = tempCertAlias {
                    _ = try? CertificateManager.deleteCertificate(alias: alias)
                }

                // Get signer name from certificate
                let signerName = SecCertificateCopySubjectSummary(identity.certificate) as? String ?? "Neurosign User"

                let formatter = ISO8601DateFormatter()
                resolver([
                    "pdfUrl": outputUrl.absoluteString,
                    "signatureValid": true,
                    "signerName": signerName,
                    "signedAt": formatter.string(from: Date()),
                ] as [String: Any])
            } catch {
                rejecter("SIGNATURE_FAILED", error.localizedDescription, error)
            }
        }
    }

    // MARK: - verifySignature

    public func verifySignature(
        pdfUrl: String,
        resolver: @escaping RNResolver,
        rejecter: @escaping RNRejecter
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = self // retain self for consistency
            do {
                guard let url = URL(string: pdfUrl) ?? URL(fileURLWithPath: pdfUrl) as URL? else {
                    rejecter("INVALID_INPUT", "Invalid PDF URL: \(pdfUrl)", nil)
                    return
                }

                let signatures = try PdfSigner.verifySignatures(pdfUrl: url)

                let sigArray = signatures.map { sig -> [String: Any] in
                    return [
                        "signerName": sig.signerName,
                        "signedAt": sig.signedAt,
                        "valid": sig.valid,
                        "trusted": sig.trusted,
                        "reason": sig.reason,
                    ]
                }

                resolver([
                    "signed": !signatures.isEmpty,
                    "signatures": sigArray,
                ] as [String: Any])
            } catch {
                rejecter("VERIFICATION_FAILED", error.localizedDescription, error)
            }
        }
    }

    // MARK: - Certificate Management (dispatched to background)

    public func importCertificate(
        certificatePath: String,
        password: String,
        alias: String,
        resolver: @escaping RNResolver,
        rejecter: @escaping RNRejecter
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let info = try CertificateManager.importP12(fileUrl: certificatePath, password: password, alias: alias)
                resolver(info.toDictionary())
            } catch {
                rejecter("CERTIFICATE_ERROR", error.localizedDescription, error)
            }
        }
    }

    public func generateSelfSignedCertificate(
        commonName: String,
        organization: String,
        country: String,
        validityDays: Int,
        alias: String,
        keyAlgorithm: String,
        resolver: @escaping RNResolver,
        rejecter: @escaping RNRejecter
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let info = try CertificateManager.generateSelfSigned(
                    commonName: commonName,
                    organization: organization,
                    country: country,
                    validityDays: validityDays,
                    alias: alias,
                    keyAlgorithm: keyAlgorithm
                )
                resolver(info.toDictionary())
            } catch {
                rejecter("CERTIFICATE_ERROR", error.localizedDescription, error)
            }
        }
    }

    public func listCertificates(
        resolver: @escaping RNResolver,
        rejecter: @escaping RNRejecter
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let certs = CertificateManager.listCertificates()
            resolver(certs.map { $0.toDictionary() })
        }
    }

    public func deleteCertificate(
        alias: String,
        resolver: @escaping RNResolver,
        rejecter: @escaping RNRejecter
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try CertificateManager.deleteCertificate(alias: alias)
                resolver(NSNumber(value: result))
            } catch {
                rejecter("CERTIFICATE_ERROR", error.localizedDescription, error)
            }
        }
    }

    // MARK: - External Signing

    @objc public func prepareForExternalSigning(
        pdfUrl: String,
        reason: String,
        location: String,
        contactInfo: String,
        resolver: @escaping RNResolver,
        rejecter: @escaping RNRejecter
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                rejecter("INTERNAL_ERROR", "Module deallocated", nil)
                return
            }
            do {
                guard let pdfFileUrl = self.resolveFileUrl(pdfUrl) else {
                    rejecter("INVALID_INPUT", "Invalid PDF URL: \(pdfUrl)", nil)
                    return
                }

                let outputUrl = self.tempDirectory.appendingPathComponent(
                    "\(UUID().uuidString)_prepared.pdf"
                )

                let result = try PdfSigner.prepareForExternalSigning(
                    pdfUrl: pdfFileUrl,
                    reason: reason,
                    location: location,
                    contactInfo: contactInfo,
                    outputUrl: outputUrl
                )

                let hashHex = result.hash.map { String(format: "%02x", $0) }.joined()

                resolver([
                    "preparedPdfUrl": outputUrl.absoluteString,
                    "hash": hashHex,
                    "hashAlgorithm": result.hashAlgorithm,
                ] as [String: Any])
            } catch {
                rejecter("EXTERNAL_SIGNING_FAILED", error.localizedDescription, error)
            }
        }
    }

    @objc public func completeExternalSigning(
        preparedPdfUrl: String,
        signature: String,
        resolver: @escaping RNResolver,
        rejecter: @escaping RNRejecter
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                rejecter("INTERNAL_ERROR", "Module deallocated", nil)
                return
            }
            do {
                guard let preparedUrl = self.resolveFileUrl(preparedPdfUrl) else {
                    rejecter("INVALID_INPUT", "Invalid prepared PDF URL", nil)
                    return
                }
                guard let cmsData = Data(base64Encoded: signature) else {
                    rejecter("INVALID_INPUT", "Invalid base64 signature data", nil)
                    return
                }

                let outputUrl = self.tempDirectory.appendingPathComponent(
                    "\(UUID().uuidString)_externally_signed.pdf"
                )

                try PdfSigner.completeExternalSigning(
                    preparedPdfUrl: preparedUrl,
                    cmsSignature: cmsData,
                    outputUrl: outputUrl
                )

                resolver([
                    "pdfUrl": outputUrl.absoluteString,
                ] as [String: Any])
            } catch {
                rejecter("EXTERNAL_SIGNING_FAILED", error.localizedDescription, error)
            }
        }
    }

    // MARK: - cleanupTempFiles

    public func cleanupTempFiles(
        resolver: @escaping RNResolver,
        rejecter: @escaping RNRejecter
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                rejecter("INTERNAL_ERROR", "Module deallocated", nil)
                return
            }
            do {
                let tempDir = self.tempDirectory
                if self.fileManager.fileExists(atPath: tempDir.path) {
                    try self.fileManager.removeItem(at: tempDir)
                }
                resolver(NSNumber(value: true))
            } catch {
                rejecter("CLEANUP_FAILED", error.localizedDescription, error)
            }
        }
    }

    // MARK: - Private Helpers

    private func loadImage(from urlString: String) -> UIImage? {
        if let url = URL(string: urlString), url.isFileURL {
            return UIImage(contentsOfFile: url.path)
        }

        if urlString.hasPrefix("/") {
            return UIImage(contentsOfFile: urlString)
        }

        if urlString.hasPrefix("file://") {
            let path = String(urlString.dropFirst("file://".count))
            return UIImage(contentsOfFile: path)
        }

        return nil
    }

    private func aspectFitRect(for imageSize: CGSize, in containerSize: CGSize, origin: CGPoint) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: origin, size: containerSize)
        }

        let widthRatio = containerSize.width / imageSize.width
        let heightRatio = containerSize.height / imageSize.height
        let scale = min(widthRatio, heightRatio)

        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale

        let x = origin.x + (containerSize.width - scaledWidth) / 2
        let y = origin.y + (containerSize.height - scaledHeight) / 2

        return CGRect(x: x, y: y, width: scaledWidth, height: scaledHeight)
    }
}
