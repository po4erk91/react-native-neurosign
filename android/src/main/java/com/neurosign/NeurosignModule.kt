package com.neurosign

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import com.facebook.react.bridge.*
import kotlinx.coroutines.*
import android.net.Uri
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

class NeurosignModule(reactContext: ReactApplicationContext) :
    NativeNeurosignSpec(reactContext) {

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    private val tempDir: File
        get() {
            val dir = File(reactApplicationContext.cacheDir, "neurosign")
            if (!dir.exists()) dir.mkdirs()
            return dir
        }

    override fun getName(): String = NAME

    // MARK: - generatePdf

    override fun generatePdf(options: ReadableMap, promise: Promise) {
        val imageUrls = options.getArray("imageUrls")
        if (imageUrls == null || imageUrls.size() == 0) {
            promise.reject("INVALID_INPUT", "imageUrls array must not be empty")
            return
        }

        val fileName = if (options.hasKey("fileName")) options.getString("fileName") ?: "document" else "document"
        val pageSize = if (options.hasKey("pageSize")) options.getString("pageSize") ?: "A4" else "A4"
        val pageMargin = if (options.hasKey("pageMargin")) options.getDouble("pageMargin").toFloat() else 20f
        val quality = if (options.hasKey("quality")) options.getInt("quality") else 90

        scope.launch {
            try {
                val pages = mutableListOf<PdfPageData>()

                for (i in 0 until imageUrls.size()) {
                    val urlString = imageUrls.getString(i) ?: continue
                    val bitmap = loadBitmap(urlString) ?: continue

                    val targetSize = getPageSize(pageSize, bitmap)

                    // Calculate draw rect with aspect fit (in PDF points)
                    val drawableWidth = targetSize.first - pageMargin * 2
                    val drawableHeight = targetSize.second - pageMargin * 2
                    val drawRect = aspectFitRect(
                        bitmap.width.toFloat(),
                        bitmap.height.toFloat(),
                        drawableWidth,
                        drawableHeight,
                        pageMargin,
                        pageMargin
                    )

                    // Compress to JPEG at full native resolution
                    val jpegStream = java.io.ByteArrayOutputStream()
                    bitmap.compress(Bitmap.CompressFormat.JPEG, quality, jpegStream)
                    val jpegBytes = jpegStream.toByteArray()

                    pages.add(PdfPageData(
                        jpegBytes = jpegBytes,
                        imgWidth = bitmap.width,
                        imgHeight = bitmap.height,
                        pageWidthPt = targetSize.first,
                        pageHeightPt = targetSize.second,
                        drawX = drawRect.left,
                        // PDF Y-axis is bottom-up: convert from top-down
                        drawY = targetSize.second - drawRect.bottom,
                        drawW = drawRect.width(),
                        drawH = drawRect.height()
                    ))
                    bitmap.recycle()
                }

                if (pages.isEmpty()) {
                    promise.reject("INVALID_INPUT", "No valid images to process")
                    return@launch
                }

                val outputFileName = if (fileName.endsWith(".pdf")) fileName else "$fileName.pdf"
                val outputFile = File(tempDir, outputFileName)

                // Write PDF directly with JPEG images at native resolution
                writePdfWithImages(outputFile, pages)

                val result = Arguments.createMap().apply {
                    putString("pdfUrl", "file://${outputFile.absolutePath}")
                    putInt("pageCount", pages.size)
                }
                promise.resolve(result)
            } catch (e: Exception) {
                promise.reject("PDF_GENERATION_FAILED", e.message, e)
            }
        }
    }

    /**
     * Write a PDF file with JPEG images embedded at their native resolution.
     * This avoids Android's PdfDocument which downsamples images to 72 DPI.
     *
     * PDF structure:
     *   1 0 obj - Catalog
     *   2 0 obj - Pages
     *   For each page i (0-based):
     *     (3 + i*3) 0 obj - Image XObject (JPEG)
     *     (4 + i*3) 0 obj - Content stream (image placement)
     *     (5 + i*3) 0 obj - Page dictionary
     */
    private data class PdfPageData(
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

    private fun writePdfWithImages(outputFile: File, pages: List<PdfPageData>) {
        val out = java.io.ByteArrayOutputStream()
        val offsets = mutableMapOf<Int, Int>() // objNum -> byte offset
        val ff = { v: Float -> String.format(java.util.Locale.US, "%.4f", v) }

        // Header
        out.write("%PDF-1.4\n%\u00E2\u00E3\u00CF\u00D3\n".toByteArray(Charsets.ISO_8859_1))

        val numPages = pages.size
        // Object numbers:
        // 1 = Catalog, 2 = Pages
        // Per page: imgObj = 3+i*3, csObj = 4+i*3, pageObj = 5+i*3
        val totalObjects = 2 + numPages * 3

        // Page object numbers for /Kids array
        val pageObjNums = (0 until numPages).map { 5 + it * 3 }

        // ── Write Image XObjects and Content Streams for each page ──
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

            // Content stream: position image on page
            val csContent = "q\n${ff(pg.drawW)} 0 0 ${ff(pg.drawH)} ${ff(pg.drawX)} ${ff(pg.drawY)} cm\n/Img Do\nQ\n"
            val csBytes = csContent.toByteArray(Charsets.US_ASCII)

            offsets[csObjNum] = out.size()
            val csHeader = "$csObjNum 0 obj\n<< /Length ${csBytes.size} >>\nstream\n"
            out.write(csHeader.toByteArray(Charsets.US_ASCII))
            out.write(csBytes)
            out.write("\nendstream\nendobj\n".toByteArray(Charsets.US_ASCII))
        }

        // ── Write Page objects ──
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

        // ── Pages object ──
        offsets[2] = out.size()
        val kidsStr = pageObjNums.joinToString(" ") { "$it 0 R" }
        val pagesObj = "2 0 obj\n<< /Type /Pages /Kids [$kidsStr] /Count $numPages >>\nendobj\n"
        out.write(pagesObj.toByteArray(Charsets.US_ASCII))

        // ── Catalog ──
        offsets[1] = out.size()
        val catalogObj = "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"
        out.write(catalogObj.toByteArray(Charsets.US_ASCII))

        // ── Cross-reference table ──
        val xrefOffset = out.size()
        val xrefSb = StringBuilder()
        xrefSb.append("xref\n")
        xrefSb.append("0 ${totalObjects + 1}\n")
        xrefSb.append("0000000000 65535 f \n")
        for (objNum in 1..totalObjects) {
            val offset = offsets[objNum] ?: 0
            xrefSb.append(String.format("%010d 00000 n \n", offset))
        }

        // ── Trailer ──
        xrefSb.append("trailer\n")
        xrefSb.append("<< /Size ${totalObjects + 1} /Root 1 0 R >>\n")
        xrefSb.append("startxref\n")
        xrefSb.append("$xrefOffset\n")
        xrefSb.append("%%EOF\n")
        out.write(xrefSb.toString().toByteArray(Charsets.US_ASCII))

        outputFile.writeBytes(out.toByteArray())
    }

    // MARK: - addSignatureImage

    override fun addSignatureImage(options: ReadableMap, promise: Promise) {
        val pdfUrl = options.getString("pdfUrl")
        val signatureImageUrl = options.getString("signatureImageUrl")
        val pageIndex = options.getInt("pageIndex")
        val x = options.getDouble("x").toFloat()
        val y = options.getDouble("y").toFloat()
        val width = options.getDouble("width").toFloat()
        val height = options.getDouble("height").toFloat()

        if (pdfUrl == null || signatureImageUrl == null) {
            promise.reject("INVALID_INPUT", "pdfUrl and signatureImageUrl are required")
            return
        }

        scope.launch {
            try {
                val pdfFile = urlToFile(pdfUrl)
                val signatureBitmap = loadBitmap(signatureImageUrl)
                    ?: throw Exception("Cannot load signature image")

                // Flatten transparency: draw onto white background (JPEG has no alpha)
                val flatBitmap = Bitmap.createBitmap(
                    signatureBitmap.width, signatureBitmap.height, Bitmap.Config.ARGB_8888
                )
                val canvas = Canvas(flatBitmap)
                canvas.drawColor(android.graphics.Color.WHITE)
                canvas.drawBitmap(signatureBitmap, 0f, 0f, null)
                signatureBitmap.recycle()

                // Compress to JPEG bytes for embedding in PDF
                val jpegStream = java.io.ByteArrayOutputStream()
                flatBitmap.compress(Bitmap.CompressFormat.JPEG, 95, jpegStream)
                val jpegBytes = jpegStream.toByteArray()
                val imgWidth = flatBitmap.width
                val imgHeight = flatBitmap.height
                flatBitmap.recycle()

                val visBaseName = pdfFile.nameWithoutExtension
                val outputFile = File(tempDir, "${visBaseName}_visual.pdf")

                // Use incremental update to preserve vector content
                PdfSigner.addSignatureImage(
                    pdfFile = pdfFile,
                    imageBytes = jpegBytes,
                    imageWidth = imgWidth,
                    imageHeight = imgHeight,
                    pageIndex = pageIndex,
                    x = x,
                    y = y,
                    width = width,
                    height = height,
                    outputFile = outputFile
                )

                val result = Arguments.createMap().apply {
                    putString("pdfUrl", "file://${outputFile.absolutePath}")
                }
                promise.resolve(result)
            } catch (e: Exception) {
                promise.reject("PDF_GENERATION_FAILED", e.message, e)
            }
        }
    }

    // MARK: - renderPdfPage

    override fun renderPdfPage(options: ReadableMap, promise: Promise) {
        val pdfUrl = options.getString("pdfUrl")
        val pageIndex = options.getInt("pageIndex")
        val width = options.getDouble("width").toInt()
        val height = options.getDouble("height").toInt()

        if (pdfUrl == null) {
            promise.reject("INVALID_INPUT", "pdfUrl is required")
            return
        }

        scope.launch {
            try {
                val pdfFile = urlToFile(pdfUrl)
                val descriptor = ParcelFileDescriptor.open(pdfFile, ParcelFileDescriptor.MODE_READ_ONLY)
                val renderer = PdfRenderer(descriptor)
                val totalPages = renderer.pageCount

                if (pageIndex < 0 || pageIndex >= totalPages) {
                    promise.reject("INVALID_INPUT", "pageIndex $pageIndex out of range (0..${totalPages - 1})")
                    renderer.close()
                    descriptor.close()
                    return@launch
                }

                val pdfPage = renderer.openPage(pageIndex)
                val pageWidth = pdfPage.width
                val pageHeight = pdfPage.height

                // Aspect-fit render size
                val scaleX = width.toFloat() / pageWidth
                val scaleY = height.toFloat() / pageHeight
                val scale = minOf(scaleX, scaleY)
                val renderWidth = (pageWidth * scale).toInt()
                val renderHeight = (pageHeight * scale).toInt()

                val bitmap = Bitmap.createBitmap(renderWidth, renderHeight, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(bitmap)
                canvas.drawColor(android.graphics.Color.WHITE)

                val matrix = android.graphics.Matrix()
                matrix.setScale(scale, scale)
                pdfPage.render(bitmap, null, matrix, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                pdfPage.close()
                renderer.close()
                descriptor.close()

                val outputFile = File(tempDir, "page_${pageIndex}_${UUID.randomUUID()}.png")
                FileOutputStream(outputFile).use { out ->
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
                }
                bitmap.recycle()

                val result = Arguments.createMap().apply {
                    putString("imageUrl", "file://${outputFile.absolutePath}")
                    putDouble("pageWidth", pageWidth.toDouble())
                    putDouble("pageHeight", pageHeight.toDouble())
                    putInt("pageCount", totalPages)
                }
                promise.resolve(result)
            } catch (e: Exception) {
                promise.reject("PDF_GENERATION_FAILED", e.message, e)
            }
        }
    }

    // MARK: - signPdf

    override fun signPdf(options: ReadableMap, promise: Promise) {
        val pdfUrl = options.getString("pdfUrl")
        val certificateType = options.getString("certificateType")

        if (pdfUrl == null || certificateType == null) {
            promise.reject("INVALID_INPUT", "pdfUrl and certificateType are required")
            return
        }

        scope.launch {
            try {
                val identity: CertificateManager.SigningIdentity = when (certificateType) {
                    "p12" -> {
                        val path = options.getString("certificatePath")
                            ?: throw IllegalArgumentException("certificatePath required for p12 type")
                        val password = options.getString("certificatePassword")
                            ?: throw IllegalArgumentException("certificatePassword required for p12 type")
                        CertificateManager.getSigningIdentityFromP12(path, password)
                    }
                    "keychain" -> {
                        val alias = options.getString("keychainAlias")
                            ?: throw IllegalArgumentException("keychainAlias required for keychain type")
                        CertificateManager.getSigningIdentity(alias)
                    }
                    "selfSigned" -> {
                        val alias = "temp_selfsigned_${UUID.randomUUID().toString().take(8)}"
                        CertificateManager.generateSelfSigned(
                            commonName = "Neurosign User",
                            organization = "",
                            country = "",
                            validityDays = 365,
                            alias = alias
                        )
                        CertificateManager.getSigningIdentity(alias)
                    }
                    else -> throw IllegalArgumentException("Unknown certificateType: $certificateType")
                }

                val pdfFile = urlToFile(pdfUrl)
                val reason = if (options.hasKey("reason")) options.getString("reason") ?: "" else ""
                val location = if (options.hasKey("location")) options.getString("location") ?: "" else ""
                val contactInfo = if (options.hasKey("contactInfo")) options.getString("contactInfo") ?: "" else ""

                val baseName = pdfFile.nameWithoutExtension.removeSuffix("_signed").removeSuffix("_visual")
                val outputFile = File(tempDir, "${baseName}_signed.pdf")

                PdfSigner.signPdf(
                    pdfFile = pdfFile,
                    identity = identity,
                    reason = reason,
                    location = location,
                    contactInfo = contactInfo,
                    outputFile = outputFile
                )

                val dateFormat = java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", java.util.Locale.US)
                dateFormat.timeZone = java.util.TimeZone.getTimeZone("UTC")

                val result = Arguments.createMap().apply {
                    putString("pdfUrl", "file://${outputFile.absolutePath}")
                    putBoolean("signatureValid", true)
                    putString("signerName", identity.certificate.subjectX500Principal.name)
                    putString("signedAt", dateFormat.format(java.util.Date()))
                }
                promise.resolve(result)
            } catch (e: Exception) {
                promise.reject("SIGNATURE_FAILED", e.message, e)
            }
        }
    }

    // MARK: - verifySignature

    override fun verifySignature(pdfUrl: String, promise: Promise) {
        scope.launch {
            try {
                val pdfFile = urlToFile(pdfUrl)
                val signatures = PdfSigner.verifySignatures(pdfFile)

                val sigArray = Arguments.createArray()
                for (sig in signatures) {
                    val sigMap = Arguments.createMap().apply {
                        putString("signerName", sig.signerName)
                        putString("signedAt", sig.signedAt)
                        putBoolean("valid", sig.valid)
                        putBoolean("trusted", sig.trusted)
                        putString("reason", sig.reason)
                    }
                    sigArray.pushMap(sigMap)
                }

                val result = Arguments.createMap().apply {
                    putBoolean("signed", signatures.isNotEmpty())
                    putArray("signatures", sigArray)
                }
                promise.resolve(result)
            } catch (e: Exception) {
                promise.reject("VERIFICATION_FAILED", e.message, e)
            }
        }
    }

    // MARK: - Certificate Management

    override fun importCertificate(options: ReadableMap, promise: Promise) {
        scope.launch {
            try {
                val path = options.getString("certificatePath")
                    ?: throw IllegalArgumentException("certificatePath is required")
                val password = options.getString("password")
                    ?: throw IllegalArgumentException("password is required")
                val alias = options.getString("alias")
                    ?: throw IllegalArgumentException("alias is required")

                // Resolve content:// URIs to a temp file
                val resolvedPath = resolveToFilePath(path)

                val info = CertificateManager.importP12(resolvedPath, password, alias)
                val result = Arguments.createMap()
                info.toMap().forEach { (key, value) -> result.putString(key, value) }
                promise.resolve(result)
            } catch (e: Exception) {
                promise.reject("CERTIFICATE_ERROR", e.message, e)
            }
        }
    }

    override fun generateSelfSignedCertificate(options: ReadableMap, promise: Promise) {
        scope.launch {
            try {
                val commonName = options.getString("commonName")
                    ?: throw IllegalArgumentException("commonName is required")
                val organization = if (options.hasKey("organization")) options.getString("organization") ?: "" else ""
                val country = if (options.hasKey("country")) options.getString("country") ?: "" else ""
                val validityDays = if (options.hasKey("validityDays")) options.getInt("validityDays") else 365
                val alias = options.getString("alias")
                    ?: throw IllegalArgumentException("alias is required")

                val keyAlgorithm = if (options.hasKey("keyAlgorithm")) options.getString("keyAlgorithm") ?: "RSA" else "RSA"

                val info = CertificateManager.generateSelfSigned(
                    commonName, organization, country, validityDays, alias, keyAlgorithm
                )
                val result = Arguments.createMap()
                info.toMap().forEach { (key, value) -> result.putString(key, value) }
                promise.resolve(result)
            } catch (e: Exception) {
                promise.reject("CERTIFICATE_ERROR", e.message, e)
            }
        }
    }

    override fun listCertificates(promise: Promise) {
        scope.launch {
            try {
                val certs = CertificateManager.listCertificates()
                val array = Arguments.createArray()
                for (cert in certs) {
                    val map = Arguments.createMap()
                    cert.toMap().forEach { (key, value) -> map.putString(key, value) }
                    array.pushMap(map)
                }
                promise.resolve(array)
            } catch (e: Exception) {
                promise.reject("CERTIFICATE_ERROR", e.message, e)
            }
        }
    }

    override fun deleteCertificate(alias: String, promise: Promise) {
        scope.launch {
            try {
                val result = CertificateManager.deleteCertificate(alias)
                promise.resolve(result)
            } catch (e: Exception) {
                promise.reject("CERTIFICATE_ERROR", e.message, e)
            }
        }
    }

    // MARK: - External Signing

    override fun prepareForExternalSigning(options: ReadableMap, promise: Promise) {
        scope.launch {
            try {
                val pdfUrl = options.getString("pdfUrl")
                    ?: throw IllegalArgumentException("pdfUrl is required")
                val reason = if (options.hasKey("reason")) options.getString("reason") ?: "" else ""
                val location = if (options.hasKey("location")) options.getString("location") ?: "" else ""
                val contactInfo = if (options.hasKey("contactInfo")) options.getString("contactInfo") ?: "" else ""

                val pdfFile = urlToFile(pdfUrl)
                val outputFile = File(tempDir, "${UUID.randomUUID()}_prepared.pdf")

                val (hash, hashAlgorithm) = PdfSigner.prepareForExternalSigning(
                    pdfFile, reason, location, contactInfo, outputFile
                )

                val hashHex = hash.joinToString("") { "%02x".format(it) }

                val result = Arguments.createMap().apply {
                    putString("preparedPdfUrl", "file://${outputFile.absolutePath}")
                    putString("hash", hashHex)
                    putString("hashAlgorithm", hashAlgorithm)
                }
                promise.resolve(result)
            } catch (e: Exception) {
                promise.reject("EXTERNAL_SIGNING_FAILED", e.message, e)
            }
        }
    }

    override fun completeExternalSigning(options: ReadableMap, promise: Promise) {
        scope.launch {
            try {
                val preparedPdfUrl = options.getString("preparedPdfUrl")
                    ?: throw IllegalArgumentException("preparedPdfUrl is required")
                val signatureBase64 = options.getString("signature")
                    ?: throw IllegalArgumentException("signature is required")

                val preparedFile = urlToFile(preparedPdfUrl)
                val cmsSignature = android.util.Base64.decode(signatureBase64, android.util.Base64.DEFAULT)
                val outputFile = File(tempDir, "${UUID.randomUUID()}_externally_signed.pdf")

                PdfSigner.completeExternalSigning(preparedFile, cmsSignature, outputFile)

                val result = Arguments.createMap().apply {
                    putString("pdfUrl", "file://${outputFile.absolutePath}")
                }
                promise.resolve(result)
            } catch (e: Exception) {
                promise.reject("EXTERNAL_SIGNING_FAILED", e.message, e)
            }
        }
    }

    // MARK: - exportSignature

    override fun exportSignature(viewTag: Double, format: String, quality: Double, promise: Promise) {
        promise.reject("SIGNATURE_FAILED", "Use SignaturePad component commands to export")
    }

    // MARK: - cleanupTempFiles

    override fun cleanupTempFiles(promise: Promise) {
        try {
            if (tempDir.exists()) {
                tempDir.deleteRecursively()
            }
            promise.resolve(true)
        } catch (e: Exception) {
            promise.reject("CLEANUP_FAILED", e.message, e)
        }
    }

    // MARK: - Private Helpers

    private fun resolveToFilePath(uriString: String): String {
        if (!uriString.startsWith("content://")) {
            return uriString
        }
        val uri = Uri.parse(uriString)
        val tempFile = File(tempDir, "import_${UUID.randomUUID()}.p12")
        reactApplicationContext.contentResolver.openInputStream(uri)?.use { input ->
            FileOutputStream(tempFile).use { output ->
                input.copyTo(output)
            }
        } ?: throw IllegalStateException("Cannot read file from: $uriString")
        return "file://${tempFile.absolutePath}"
    }

    private fun loadBitmap(urlString: String): Bitmap? {
        val path = urlString.removePrefix("file://")
        val file = File(path)
        return if (file.exists()) {
            BitmapFactory.decodeFile(file.absolutePath)
        } else {
            null
        }
    }

    private fun urlToFile(urlString: String): File {
        return File(urlString.removePrefix("file://"))
    }

    private fun getPageSize(pageSize: String, bitmap: Bitmap): Pair<Float, Float> {
        return when (pageSize.uppercase()) {
            "A4" -> Pair(595.28f, 841.89f)
            "LETTER" -> Pair(612f, 792f)
            "ORIGINAL" -> Pair(bitmap.width.toFloat(), bitmap.height.toFloat())
            else -> Pair(595.28f, 841.89f)
        }
    }

    private fun aspectFitRect(
        imageWidth: Float,
        imageHeight: Float,
        containerWidth: Float,
        containerHeight: Float,
        originX: Float,
        originY: Float
    ): android.graphics.RectF {
        val widthRatio = containerWidth / imageWidth
        val heightRatio = containerHeight / imageHeight
        val scale = minOf(widthRatio, heightRatio)

        val scaledWidth = imageWidth * scale
        val scaledHeight = imageHeight * scale

        val x = originX + (containerWidth - scaledWidth) / 2
        val y = originY + (containerHeight - scaledHeight) / 2

        return android.graphics.RectF(x, y, x + scaledWidth, y + scaledHeight)
    }

    companion object {
        const val NAME = "Neurosign"
    }
}
