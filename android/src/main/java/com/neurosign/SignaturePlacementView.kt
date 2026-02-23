package com.neurosign

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.widget.FrameLayout
import android.widget.ImageView
import java.io.File

class SignaturePlacementView(context: Context) : FrameLayout(context) {

    // Subviews
    private val pdfImageView: ImageView = ImageView(context).apply {
        scaleType = ImageView.ScaleType.FIT_XY
    }
    private val signatureImageView: ImageView = ImageView(context).apply {
        scaleType = ImageView.ScaleType.FIT_XY
    }

    // Density for dp→px conversion
    private val density = context.resources.displayMetrics.density

    // Configurable border/corner values (in dp, stored as px)
    private var borderPaddingPx: Float = 0f
    private var cornerLengthPx: Float = 14f * density
    private var borderRadiusPx: Float = 0f

    // Paint for dashed border
    private val dashedBorderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        color = Color.parseColor("#E94560")
        strokeWidth = 2f * density
        pathEffect = DashPathEffect(
            floatArrayOf(8f * density, 6f * density), 0f
        )
    }

    // Paint for corner handles
    private val cornerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        color = Color.parseColor("#E94560")
        strokeWidth = 3f * density
        strokeCap = Paint.Cap.ROUND
    }

    // PDF state
    private var pdfRenderer: PdfRenderer? = null
    private var pdfFileDescriptor: ParcelFileDescriptor? = null
    private var currentPageIndex: Int = 0
    private var totalPageCount: Int = 0

    // Signature position/size in view coordinates
    private var sigX: Float = 0f
    private var sigY: Float = 0f
    private var sigWidth: Float = 150f
    private var sigHeight: Float = 50f
    private var sigAspectRatio: Float = 3f

    // PDF display rect within this view (aspect-fit)
    private var pdfDisplayRect = RectF()

    // Default position (normalized 0-1, -1 = center)
    private var defaultPositionX: Float = -1f
    private var defaultPositionY: Float = -1f

    // Drag state
    private var isDragging = false
    private var dragStartX = 0f
    private var dragStartY = 0f
    private var dragStartSigX = 0f
    private var dragStartSigY = 0f

    // Pinch state
    private var isPinching = false
    private var cumulativeScale = 1.0f

    // Scale gesture detector
    private val scaleDetector: ScaleGestureDetector

    // Callbacks
    var onPlacementConfirmed: ((Map<String, Any>) -> Unit)? = null
    var onPageCount: ((Int) -> Unit)? = null

    init {
        setBackgroundColor(Color.TRANSPARENT)
        // Enable drawing over children
        setWillNotDraw(false)

        addView(pdfImageView, LayoutParams(0, 0))
        addView(signatureImageView, LayoutParams(0, 0))

        scaleDetector = ScaleGestureDetector(context, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
            private var startWidth = 0f
            private var startCenterX = 0f
            private var startCenterY = 0f

            override fun onScaleBegin(detector: ScaleGestureDetector): Boolean {
                isPinching = true
                cumulativeScale = 1.0f
                startWidth = sigWidth
                startCenterX = sigX + sigWidth / 2f
                startCenterY = sigY + sigHeight / 2f
                return true
            }

            override fun onScale(detector: ScaleGestureDetector): Boolean {
                cumulativeScale *= detector.scaleFactor
                val maxWidth = pdfDisplayRect.width() * 0.9f
                val newWidth = (startWidth * cumulativeScale).coerceIn(60f, maxWidth)
                val newHeight = newWidth / sigAspectRatio

                val newX = startCenterX - newWidth / 2f
                val newY = startCenterY - newHeight / 2f

                sigWidth = newWidth
                sigHeight = newHeight
                sigX = clampX(newX)
                sigY = clampY(newY)

                applySignatureLayout()
                invalidate()
                return true
            }

            override fun onScaleEnd(detector: ScaleGestureDetector) {
                isPinching = false
            }
        })
    }

    // MARK: - Props

    fun setPdfUrl(url: String?) {
        if (url == null) return
        loadPdf(url)
    }

    fun setSignatureImageUrl(url: String?) {
        if (url == null) return
        loadSignatureImage(url)
    }

    fun setPageIndex(index: Int) {
        if (index != currentPageIndex) {
            currentPageIndex = index
            renderCurrentPage()
        }
    }

    fun setDefaultPositionX(x: Float) {
        defaultPositionX = x
    }

    fun setDefaultPositionY(y: Float) {
        defaultPositionY = y
    }

    fun setPlaceholderBackgroundColor(color: String?) {
        if (color == null) return
        try {
            setBackgroundColor(Color.parseColor(color))
        } catch (_: Exception) {}
    }

    fun setSigBorderColor(color: String?) {
        if (color == null) return
        try {
            val parsed = Color.parseColor(color)
            dashedBorderPaint.color = parsed
            cornerPaint.color = parsed
            invalidate()
        } catch (_: Exception) {}
    }

    fun setSigBorderWidth(widthDp: Float) {
        dashedBorderPaint.strokeWidth = widthDp * density
        invalidate()
    }

    fun setSigBorderPadding(paddingDp: Float) {
        borderPaddingPx = paddingDp * density
        invalidate()
    }

    fun setSigCornerSize(sizeDp: Float) {
        cornerLengthPx = sizeDp * density
        invalidate()
    }

    fun setSigCornerWidth(widthDp: Float) {
        cornerPaint.strokeWidth = widthDp * density
        invalidate()
    }

    fun setSigBorderRadius(radiusDp: Float) {
        borderRadiusPx = radiusDp * density
        invalidate()
    }

    // MARK: - Commands

    fun confirm() {
        if (pdfDisplayRect.width() == 0f || pdfDisplayRect.height() == 0f) return

        val normalizedX = ((sigX - pdfDisplayRect.left) / pdfDisplayRect.width()).toDouble()
        val normalizedY = ((sigY - pdfDisplayRect.top) / pdfDisplayRect.height()).toDouble()
        val normalizedW = (sigWidth / pdfDisplayRect.width()).toDouble()
        val normalizedH = (sigHeight / pdfDisplayRect.height()).toDouble()

        val data = mapOf(
            "pageIndex" to currentPageIndex,
            "x" to normalizedX.coerceIn(0.0, 1.0 - normalizedW),
            "y" to normalizedY.coerceIn(0.0, 1.0 - normalizedH),
            "width" to normalizedW.coerceIn(0.0, 1.0),
            "height" to normalizedH.coerceIn(0.0, 1.0)
        )
        onPlacementConfirmed?.invoke(data)
    }

    fun reset() {
        positionSignatureDefault()
        applySignatureLayout()
        invalidate()
    }

    // MARK: - Touch handling

    private fun isTouchInsideSignature(x: Float, y: Float): Boolean {
        return x >= sigX && x <= sigX + sigWidth && y >= sigY && y <= sigY + sigHeight
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        scaleDetector.onTouchEvent(event)

        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                isDragging = isTouchInsideSignature(event.x, event.y)
                dragStartX = event.x
                dragStartY = event.y
                dragStartSigX = sigX
                dragStartSigY = sigY
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                if (!isPinching && event.pointerCount == 1 && isDragging) {
                    val dx = event.x - dragStartX
                    val dy = event.y - dragStartY
                    sigX = clampX(dragStartSigX + dx)
                    sigY = clampY(dragStartSigY + dy)
                    applySignatureLayout()
                    invalidate()
                }
                return true
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                isDragging = false
                isPinching = false
                return true
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                isDragging = false
                return true
            }
        }
        return true
    }

    // MARK: - Layout

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        if (w > 0 && h > 0) {
            renderCurrentPage()
        }
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        super.onLayout(changed, left, top, right, bottom)
        layoutPdfView()
        layoutSignatureView()
    }

    private fun layoutPdfView() {
        if (pdfDisplayRect.width() > 0 && pdfDisplayRect.height() > 0) {
            pdfImageView.layout(
                pdfDisplayRect.left.toInt(),
                pdfDisplayRect.top.toInt(),
                pdfDisplayRect.right.toInt(),
                pdfDisplayRect.bottom.toInt()
            )
        }
    }

    private fun layoutSignatureView() {
        if (sigWidth > 0 && sigHeight > 0) {
            signatureImageView.layout(
                sigX.toInt(),
                sigY.toInt(),
                (sigX + sigWidth).toInt(),
                (sigY + sigHeight).toInt()
            )
        }
    }

    private fun applySignatureLayout() {
        layoutSignatureView()
    }

    private fun applyPdfLayout() {
        layoutPdfView()
    }

    // MARK: - Drawing (dashed border + corner handles)

    override fun dispatchDraw(canvas: Canvas) {
        super.dispatchDraw(canvas)
        if (sigWidth <= 0 || sigHeight <= 0) return

        val p = borderPaddingPx
        val l = sigX - p
        val t = sigY - p
        val r = sigX + sigWidth + p
        val b = sigY + sigHeight + p
        val rad = borderRadiusPx

        // Dashed border rectangle (with optional rounded corners)
        if (rad > 0f) {
            canvas.drawRoundRect(l, t, r, b, rad, rad, dashedBorderPaint)
        } else {
            canvas.drawRect(l, t, r, b, dashedBorderPaint)
        }

        // Corner handle: top-left
        canvas.drawLine(l, t, l + cornerLengthPx, t, cornerPaint)
        canvas.drawLine(l, t, l, t + cornerLengthPx, cornerPaint)

        // Corner handle: bottom-right
        canvas.drawLine(r, b, r - cornerLengthPx, b, cornerPaint)
        canvas.drawLine(r, b, r, b - cornerLengthPx, cornerPaint)
    }

    // MARK: - Clamping

    private fun clampX(x: Float): Float {
        val minX = pdfDisplayRect.left
        val maxX = pdfDisplayRect.right - sigWidth
        return x.coerceIn(minX, maxX.coerceAtLeast(minX))
    }

    private fun clampY(y: Float): Float {
        val minY = pdfDisplayRect.top
        val maxY = pdfDisplayRect.bottom - sigHeight
        return y.coerceIn(minY, maxY.coerceAtLeast(minY))
    }

    // MARK: - PDF Loading

    private fun loadPdf(url: String) {
        try {
            closePdf()

            val file = resolveFile(url)
            if (file == null || !file.exists()) return

            pdfFileDescriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            pdfRenderer = PdfRenderer(pdfFileDescriptor!!)
            totalPageCount = pdfRenderer!!.pageCount

            onPageCount?.invoke(totalPageCount)
            renderCurrentPage()
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun closePdf() {
        try {
            pdfRenderer?.close()
            pdfFileDescriptor?.close()
        } catch (_: Exception) {}
        pdfRenderer = null
        pdfFileDescriptor = null
    }

    private fun renderCurrentPage() {
        val renderer = pdfRenderer ?: return
        if (width == 0 || height == 0) return
        if (currentPageIndex < 0 || currentPageIndex >= renderer.pageCount) return

        val page = renderer.openPage(currentPageIndex)
        val pageWidth = page.width.toFloat()
        val pageHeight = page.height.toFloat()

        val viewW = width.toFloat()
        val viewH = height.toFloat()
        val pdfAspect = pageWidth / pageHeight
        val viewAspect = viewW / viewH

        val displayW: Float
        val displayH: Float
        val displayX: Float
        val displayY: Float

        if (pdfAspect > viewAspect) {
            displayW = viewW
            displayH = viewW / pdfAspect
            displayX = 0f
            displayY = (viewH - displayH) / 2f
        } else {
            displayH = viewH
            displayW = viewH * pdfAspect
            displayX = (viewW - displayW) / 2f
            displayY = 0f
        }

        pdfDisplayRect.set(displayX, displayY, displayX + displayW, displayY + displayH)

        val scale = 2f
        val bitmapW = (displayW * scale).toInt().coerceAtLeast(1)
        val bitmapH = (displayH * scale).toInt().coerceAtLeast(1)
        val bitmap = Bitmap.createBitmap(bitmapW, bitmapH, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(Color.WHITE)
        page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
        page.close()

        pdfImageView.setImageBitmap(bitmap)
        applyPdfLayout()

        positionSignatureDefault()
        applySignatureLayout()
        invalidate()
    }

    private fun positionSignatureDefault() {
        val r = pdfDisplayRect
        if (r.width() == 0f) return

        sigWidth = r.width() * 0.25f
        sigHeight = sigWidth / sigAspectRatio

        if (defaultPositionX >= 0f && defaultPositionY >= 0f) {
            sigX = r.left + defaultPositionX * r.width()
            sigY = r.top + defaultPositionY * r.height()
        } else {
            sigX = r.left + (r.width() - sigWidth) / 2f
            sigY = r.top + (r.height() - sigHeight) / 2f
        }

        sigX = clampX(sigX)
        sigY = clampY(sigY)
    }

    // MARK: - Signature image loading

    private fun loadSignatureImage(url: String) {
        try {
            val file = resolveFile(url) ?: return
            if (!file.exists()) return

            val bitmap = BitmapFactory.decodeFile(file.absolutePath) ?: return
            sigAspectRatio = bitmap.width.toFloat() / bitmap.height.toFloat()
            signatureImageView.setImageBitmap(bitmap)

            if (pdfDisplayRect.width() > 0) {
                sigHeight = sigWidth / sigAspectRatio
                applySignatureLayout()
                invalidate()
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    // MARK: - File resolution

    private fun resolveFile(url: String): File? {
        return when {
            url.startsWith("file://") -> File(Uri.parse(url).path ?: return null)
            url.startsWith("/") -> File(url)
            url.startsWith("content://") -> {
                try {
                    val inputStream = context.contentResolver.openInputStream(Uri.parse(url)) ?: return null
                    val tempFile = File.createTempFile("neurosign_", ".tmp", context.cacheDir)
                    tempFile.outputStream().use { out -> inputStream.copyTo(out) }
                    inputStream.close()
                    tempFile
                } catch (_: Exception) { null }
            }
            else -> File(url)
        }
    }

    // MARK: - Cleanup

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        closePdf()
    }
}
