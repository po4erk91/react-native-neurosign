import Foundation
import UIKit

public typealias RNResolver = @convention(block) (Any?) -> Void
public typealias RNRejecter = @convention(block) (String?, String?, Error?) -> Void

@objcMembers
public class NeurosignImpl: NSObject {

    private let fileManager = FileManager.default

    // MARK: - Temp Directory

    private var tempDirectory: URL {
        let dir = fileManager.temporaryDirectory.appendingPathComponent("neurosign", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

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
            guard let self = self else { return }

            guard !imageUrls.isEmpty else {
                rejecter("INVALID_INPUT", "imageUrls array must not be empty", nil)
                return
            }

            let margin = CGFloat(pageMargin)
            let targetPageSize = self.pageSizeForName(pageSize)

            let format = UIGraphicsPDFRendererFormat()
            let renderer = UIGraphicsPDFRenderer(
                bounds: CGRect(origin: .zero, size: targetPageSize),
                format: format
            )

            do {
                let pdfData = renderer.pdfData { context in
                    for urlString in imageUrls {
                        guard let image = self.loadImage(from: urlString) else { continue }

                        if pageSize.uppercased() == "ORIGINAL" {
                            // Use the image's own size
                            let imgPageSize = CGSize(
                                width: image.size.width + margin * 2,
                                height: image.size.height + margin * 2
                            )
                            let pageBounds = CGRect(origin: .zero, size: imgPageSize)
                            context.beginPage(withBounds: pageBounds, pageInfo: [:])
                            let drawRect = CGRect(
                                x: margin,
                                y: margin,
                                width: image.size.width,
                                height: image.size.height
                            )
                            image.draw(in: drawRect)
                        } else {
                            context.beginPage()
                            let drawableWidth = targetPageSize.width - margin * 2
                            let drawableHeight = targetPageSize.height - margin * 2
                            let drawRect = self.aspectFitRect(
                                for: image.size,
                                in: CGSize(width: drawableWidth, height: drawableHeight),
                                origin: CGPoint(x: margin, y: margin)
                            )
                            image.draw(in: drawRect)
                        }
                    }
                }

                let outputFileName = fileName.hasSuffix(".pdf") ? fileName : "\(fileName).pdf"
                let outputUrl = self.tempDirectory.appendingPathComponent(
                    "\(UUID().uuidString)_\(outputFileName)"
                )
                try pdfData.write(to: outputUrl)

                let pageCount = imageUrls.count
                resolver([
                    "pdfUrl": outputUrl.absoluteString,
                    "pageCount": pageCount,
                ] as [String: Any])
            } catch {
                rejecter("PDF_GENERATION_FAILED", error.localizedDescription, error)
            }
        }
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
            guard let self = self else { return }

            guard let pdfFileUrl = URL(string: pdfUrl),
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
                        // PDF pages are drawn with inverted Y axis
                        cgContext.translateBy(x: 0, y: pageBox.height)
                        cgContext.scaleBy(x: 1, y: -1)
                        cgContext.drawPDFPage(page)

                        // Draw signature if this page has a placement (i is 1-based)
                        if let placement = placementMap[i - 1] {
                            // Reset transform for drawing signature
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
            guard let self = self else { return }

            guard let pdfFileUrl = URL(string: pdfUrl),
                  let pdfDocument = CGPDFDocument(pdfFileUrl as CFURL) else {
                rejecter("INVALID_INPUT", "Cannot open PDF at: \(pdfUrl)", nil)
                return
            }

            let totalPages = pdfDocument.numberOfPages

            guard pageIndex >= 0, pageIndex < totalPages else {
                rejecter("INVALID_INPUT", "pageIndex \(pageIndex) out of range (0..\(totalPages - 1))", nil)
                return
            }

            // CGPDFDocument pages are 1-indexed
            guard let page = pdfDocument.page(at: pageIndex + 1) else {
                rejecter("PDF_GENERATION_FAILED", "Cannot get page \(pageIndex)", nil)
                return
            }

            let mediaBox = page.getBoxRect(.mediaBox)
            let targetSize = CGSize(width: CGFloat(width), height: CGFloat(height))

            // Aspect-fit scale
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
        resolver: @escaping RNResolver,
        rejecter: @escaping RNRejecter
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                // Get signing identity based on certificate type
                let identity: CertificateManager.SigningIdentity

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
                    // Generate a temporary self-signed cert if not already stored
                    let alias = "temp_selfsigned_\(UUID().uuidString.prefix(8))"
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

                guard let pdfFileUrl = URL(string: pdfUrl) else {
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
                    outputUrl: outputUrl
                )

                let formatter = ISO8601DateFormatter()
                resolver([
                    "pdfUrl": outputUrl.absoluteString,
                    "signatureValid": true,
                    "signerName": "Neurosign User",
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
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let url = URL(string: pdfUrl) else {
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

    // MARK: - Certificate Management

    public func importCertificate(
        certificatePath: String,
        password: String,
        alias: String,
        resolver: @escaping RNResolver,
        rejecter: @escaping RNRejecter
    ) {
        do {
            let info = try CertificateManager.importP12(fileUrl: certificatePath, password: password, alias: alias)
            resolver(info.toDictionary())
        } catch {
            rejecter("CERTIFICATE_ERROR", error.localizedDescription, error)
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

    public func listCertificates(
        resolver: @escaping RNResolver,
        rejecter: @escaping RNRejecter
    ) {
        let certs = CertificateManager.listCertificates()
        resolver(certs.map { $0.toDictionary() })
    }

    public func deleteCertificate(
        alias: String,
        resolver: @escaping RNResolver,
        rejecter: @escaping RNRejecter
    ) {
        do {
            let result = try CertificateManager.deleteCertificate(alias: alias)
            resolver(NSNumber(value: result))
        } catch {
            rejecter("CERTIFICATE_ERROR", error.localizedDescription, error)
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
            guard let self = self else { return }
            do {
                guard let pdfFileUrl = URL(string: pdfUrl) else {
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
            guard let self = self else { return }
            do {
                guard let preparedUrl = URL(string: preparedPdfUrl) else {
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
        do {
            let tempDir = tempDirectory
            if fileManager.fileExists(atPath: tempDir.path) {
                try fileManager.removeItem(at: tempDir)
            }
            resolver(NSNumber(value: true))
        } catch {
            rejecter("CLEANUP_FAILED", error.localizedDescription, error)
        }
    }

    // MARK: - Private Helpers

    private func loadImage(from urlString: String) -> UIImage? {
        guard let url = URL(string: urlString) else { return nil }

        if url.isFileURL {
            return UIImage(contentsOfFile: url.path)
        }

        // Handle file:// URLs
        if urlString.hasPrefix("file://") {
            let path = urlString.replacingOccurrences(of: "file://", with: "")
            return UIImage(contentsOfFile: path)
        }

        return nil
    }

    private func aspectFitRect(for imageSize: CGSize, in containerSize: CGSize, origin: CGPoint) -> CGRect {
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
