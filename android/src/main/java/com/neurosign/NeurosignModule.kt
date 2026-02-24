package com.neurosign

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import com.facebook.react.bridge.*
import kotlinx.coroutines.*
import android.net.Uri
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

class NeurosignModule(reactContext: ReactApplicationContext) :
    NativeNeurosignSpec(reactContext) {

    private val exceptionHandler = CoroutineExceptionHandler { _, throwable ->
        Log.e(NAME, "Uncaught coroutine exception", throwable)
    }
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob() + exceptionHandler)

    override fun invalidate() {
        super.invalidate()
        scope.cancel()
    }

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
                val pages = mutableListOf<PdfGenerator.PageData>()

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

                    pages.add(PdfGenerator.PageData(
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
                PdfGenerator.writePdfWithImages(outputFile, pages)

                val result = Arguments.createMap().apply {
                    putString("pdfUrl", "file://${outputFile.absolutePath}")
                    putInt("pageCount", pages.size)
                    putInt("fileSize", outputFile.length().toInt())
                }
                promise.resolve(result)
            } catch (e: Exception) {
                promise.reject("PDF_GENERATION_FAILED", e.message, e)
            }
        }
    }

    // MARK: - addSignatureImage

    override fun addSignatureImage(options: ReadableMap, promise: Promise) {
        val pdfUrl = options.getString("pdfUrl")
        val signatureImageUrl = options.getString("signatureImageUrl")

        if (pdfUrl == null || signatureImageUrl == null) {
            promise.reject("INVALID_INPUT", "pdfUrl and signatureImageUrl are required")
            return
        }

        // Parse placements array or fall back to single placement fields
        data class Placement(val pageIndex: Int, val x: Float, val y: Float, val width: Float, val height: Float)

        val placements = mutableListOf<Placement>()
        val rawPlacements = if (options.hasKey("placements")) options.getArray("placements") else null

        if (rawPlacements != null && rawPlacements.size() > 0) {
            for (i in 0 until rawPlacements.size()) {
                val p = rawPlacements.getMap(i) ?: continue
                placements.add(Placement(
                    pageIndex = p.getInt("pageIndex"),
                    x = p.getDouble("x").toFloat(),
                    y = p.getDouble("y").toFloat(),
                    width = p.getDouble("width").toFloat(),
                    height = p.getDouble("height").toFloat()
                ))
            }
        } else {
            // Backward compat: single placement
            placements.add(Placement(
                pageIndex = options.getInt("pageIndex"),
                x = options.getDouble("x").toFloat(),
                y = options.getDouble("y").toFloat(),
                width = options.getDouble("width").toFloat(),
                height = options.getDouble("height").toFloat()
            ))
        }

        scope.launch {
            try {
                val pdfFile = urlToFile(pdfUrl)
                val signatureBitmap = loadBitmap(signatureImageUrl)
                    ?: throw Exception("Cannot load signature image")

                val imgWidth: Int
                val imgHeight: Int
                val pixels: IntArray

                try {
                    imgWidth = signatureBitmap.width
                    imgHeight = signatureBitmap.height

                    // Guard against OOM from oversized images
                    val maxPixels = 4096 * 4096
                    val totalPixels = imgWidth.toLong() * imgHeight.toLong()
                    if (totalPixels > maxPixels) {
                        throw IllegalArgumentException(
                            "Signature image too large: ${imgWidth}x${imgHeight} " +
                            "(max ${maxPixels / 1024 / 1024}M pixels)"
                        )
                    }

                    // Extract raw ARGB pixels and split into RGB + Alpha channels
                    pixels = IntArray(imgWidth * imgHeight)
                    signatureBitmap.getPixels(pixels, 0, imgWidth, 0, 0, imgWidth, imgHeight)
                } finally {
                    signatureBitmap.recycle()
                }

                val rgbBytes = ByteArray(imgWidth * imgHeight * 3)
                val alphaBytes = ByteArray(imgWidth * imgHeight)
                var hasAlpha = false

                for (i in pixels.indices) {
                    val pixel = pixels[i]
                    rgbBytes[i * 3]     = ((pixel shr 16) and 0xFF).toByte() // R
                    rgbBytes[i * 3 + 1] = ((pixel shr 8) and 0xFF).toByte()  // G
                    rgbBytes[i * 3 + 2] = (pixel and 0xFF).toByte()           // B
                    val alpha = ((pixel shr 24) and 0xFF).toByte()
                    alphaBytes[i] = alpha
                    if (alpha != 0xFF.toByte()) hasAlpha = true
                }

                val visBaseName = pdfFile.nameWithoutExtension
                val outputFile = File(tempDir, "${visBaseName}_visual.pdf")

                // Chain incremental updates for each placement
                val intermediateTempFiles = mutableListOf<File>()
                var currentInput = pdfFile
                try {
                    for ((index, p) in placements.withIndex()) {
                        val isLast = index == placements.size - 1
                        val currentOutput = if (isLast) outputFile
                            else File(tempDir, "sig_step_${UUID.randomUUID()}.pdf").also {
                                intermediateTempFiles.add(it)
                            }

                        PdfSigner.addSignatureImage(
                            pdfFile = currentInput,
                            rgbBytes = rgbBytes,
                            alphaBytes = if (hasAlpha) alphaBytes else null,
                            imageWidth = imgWidth,
                            imageHeight = imgHeight,
                            pageIndex = p.pageIndex,
                            x = p.x,
                            y = p.y,
                            width = p.width,
                            height = p.height,
                            outputFile = currentOutput
                        )

                        currentInput = currentOutput
                    }
                } finally {
                    // Always clean up intermediate temp files
                    intermediateTempFiles.forEach { it.delete() }
                }

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
                try {
                val renderer = PdfRenderer(descriptor)
                try {
                val totalPages = renderer.pageCount

                if (pageIndex < 0 || pageIndex >= totalPages) {
                    promise.reject("INVALID_INPUT", "pageIndex $pageIndex out of range (0..${totalPages - 1})")
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
                try {
                val canvas = Canvas(bitmap)
                canvas.drawColor(android.graphics.Color.WHITE)

                val matrix = android.graphics.Matrix()
                matrix.setScale(scale, scale)
                pdfPage.render(bitmap, null, matrix, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                pdfPage.close()

                val outputFile = File(tempDir, "page_${pageIndex}_${UUID.randomUUID()}.png")
                FileOutputStream(outputFile).use { out ->
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
                }

                val result = Arguments.createMap().apply {
                    putString("imageUrl", "file://${outputFile.absolutePath}")
                    putDouble("pageWidth", pageWidth.toDouble())
                    putDouble("pageHeight", pageHeight.toDouble())
                    putInt("pageCount", totalPages)
                }
                promise.resolve(result)
                } finally {
                    bitmap.recycle()
                }
                } finally {
                    renderer.close()
                }
                } finally {
                    descriptor.close()
                }
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
                var tempCertAlias: String? = null
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
                        tempCertAlias = alias
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
                val tsaUrl = if (options.hasKey("tsaUrl")) options.getString("tsaUrl") else null

                val baseName = pdfFile.nameWithoutExtension.removeSuffix("_signed").removeSuffix("_visual")
                val outputFile = File(tempDir, "${baseName}_signed.pdf")

                PdfSigner.signPdf(
                    pdfFile = pdfFile,
                    identity = identity,
                    reason = reason,
                    location = location,
                    contactInfo = contactInfo,
                    tsaUrl = tsaUrl,
                    outputFile = outputFile
                )

                // Clean up temp self-signed certificate from KeyStore
                tempCertAlias?.let { alias ->
                    try { CertificateManager.deleteCertificate(alias) } catch (_: Exception) {}
                }

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
        scope.launch {
            try {
                if (tempDir.exists()) {
                    tempDir.deleteRecursively()
                }
                promise.resolve(true)
            } catch (e: Exception) {
                promise.reject("CLEANUP_FAILED", e.message, e)
            }
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
