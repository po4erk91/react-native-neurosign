package com.neurosign

import android.content.Context
import android.graphics.*
import android.view.MotionEvent
import android.view.View
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

/**
 * Native Android signature pad with smooth Bézier curve rendering.
 * Supports pressure-sensitive input from styluses and fingers.
 *
 * Uses the Square "Smoother Signatures" algorithm:
 * - Cubic Bézier curves between touch points
 * - Variable stroke width based on velocity
 * - Velocity-weighted smoothing
 */
class SignaturePadView(context: Context) : View(context) {

    // Drawing state
    private val currentPath = Path()
    private val paths = mutableListOf<Pair<Path, Paint>>()
    private val undoStack = mutableListOf<List<Pair<Path, Paint>>>()
    private val redoStack = mutableListOf<List<Pair<Path, Paint>>>()

    // Touch tracking for Bézier smoothing
    private val points = mutableListOf<TimedPoint>()
    private var lastVelocity = 0f
    private var lastWidth = 0f

    // Paint configuration
    private val currentPaint = Paint().apply {
        isAntiAlias = true
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
        color = Color.BLACK
        strokeWidth = 4f
    }

    // Props
    var strokeColor: Int = Color.BLACK
        set(value) {
            field = value
            currentPaint.color = value
        }

    var strokeWidth: Float = 4f
        set(value) {
            field = value
            currentPaint.strokeWidth = value
        }

    var minStrokeWidth: Float = 1f
    var maxStrokeWidth: Float = 10f

    private var bgColor: Int = Color.WHITE

    // Callbacks
    var onDrawingChanged: ((Boolean) -> Unit)? = null
    var onSignatureExported: ((String) -> Unit)? = null

    init {
        setBackgroundColor(Color.WHITE)
    }

    override fun setBackgroundColor(color: Int) {
        bgColor = color
        super.setBackgroundColor(color)
    }

    // MARK: - Drawing

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)

        // Draw completed paths
        for ((path, paint) in paths) {
            canvas.drawPath(path, paint)
        }

        // Draw current path
        canvas.drawPath(currentPath, currentPaint)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        val x = event.x
        val y = event.y
        val pressure = event.pressure

        when (event.action) {
            MotionEvent.ACTION_DOWN -> {
                redoStack.clear()
                currentPath.reset()
                currentPath.moveTo(x, y)
                points.clear()
                points.add(TimedPoint(x, y, System.currentTimeMillis(), pressure))
                lastVelocity = 0f
                lastWidth = strokeWidth
                invalidate()
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                val newPoint = TimedPoint(x, y, System.currentTimeMillis(), pressure)
                points.add(newPoint)

                if (points.size >= 4) {
                    // Use cubic Bézier for smooth curves
                    val p0 = points[points.size - 4]
                    val p1 = points[points.size - 3]
                    val p2 = points[points.size - 2]
                    val p3 = points[points.size - 1]

                    // Calculate control points for smooth curve
                    val cx1 = (p0.x + p1.x) / 2
                    val cy1 = (p0.y + p1.y) / 2
                    val cx2 = (p1.x + p2.x) / 2
                    val cy2 = (p1.y + p2.y) / 2

                    currentPath.quadTo(p1.x, p1.y, cx2, cy2)

                    // Adjust width based on velocity (Square algorithm)
                    val velocity = calculateVelocity(p2, p3)
                    val newWidth = calculateStrokeWidth(velocity, pressure)
                    currentPaint.strokeWidth = newWidth
                    lastVelocity = velocity
                    lastWidth = newWidth
                } else {
                    currentPath.lineTo(x, y)
                }

                invalidate()
                return true
            }
            MotionEvent.ACTION_UP -> {
                // Save current path
                val pathCopy = Path(currentPath)
                val paintCopy = Paint(currentPaint)
                paths.add(Pair(pathCopy, paintCopy))
                currentPath.reset()
                points.clear()

                onDrawingChanged?.invoke(paths.isNotEmpty())
                invalidate()
                return true
            }
        }
        return super.onTouchEvent(event)
    }

    // MARK: - Commands

    fun clear() {
        if (paths.isNotEmpty()) {
            undoStack.add(paths.toList())
        }
        paths.clear()
        currentPath.reset()
        redoStack.clear()
        invalidate()
        onDrawingChanged?.invoke(false)
    }

    fun undo() {
        if (paths.isNotEmpty()) {
            redoStack.add(paths.toList())
            val last = paths.removeAt(paths.size - 1)
            invalidate()
            onDrawingChanged?.invoke(paths.isNotEmpty())
        }
    }

    fun redo() {
        if (redoStack.isNotEmpty()) {
            val restored = redoStack.removeAt(redoStack.size - 1)
            paths.clear()
            paths.addAll(restored)
            invalidate()
            onDrawingChanged?.invoke(paths.isNotEmpty())
        }
    }

    fun exportSignature(format: String, quality: Int) {
        if (paths.isEmpty()) {
            onSignatureExported?.invoke("")
            return
        }

        // Calculate signature bounds
        val bounds = calculateBounds()
        val padding = 10f
        val signatureWidth = (bounds.width() + padding * 2).toInt().coerceAtLeast(1)
        val signatureHeight = (bounds.height() + padding * 2).toInt().coerceAtLeast(1)

        val bitmap = Bitmap.createBitmap(signatureWidth, signatureHeight, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawColor(Color.TRANSPARENT)

        // Translate to crop to signature bounds
        canvas.translate(-bounds.left + padding, -bounds.top + padding)

        for ((path, paint) in paths) {
            canvas.drawPath(path, paint)
        }

        // Save to temp
        val tempDir = File(context.cacheDir, "neurosign")
        if (!tempDir.exists()) tempDir.mkdirs()

        val extension = if (format == "png") "png" else "png"
        val fileName = "${UUID.randomUUID()}_signature.$extension"
        val file = File(tempDir, fileName)

        FileOutputStream(file).use { fos ->
            bitmap.compress(Bitmap.CompressFormat.PNG, quality, fos)
        }
        bitmap.recycle()

        onSignatureExported?.invoke("file://${file.absolutePath}")
    }

    // MARK: - Private Helpers

    private fun calculateVelocity(p1: TimedPoint, p2: TimedPoint): Float {
        val dt = (p2.timestamp - p1.timestamp).toFloat().coerceAtLeast(1f)
        val dx = p2.x - p1.x
        val dy = p2.y - p1.y
        val distance = Math.sqrt((dx * dx + dy * dy).toDouble()).toFloat()
        return distance / dt
    }

    private fun calculateStrokeWidth(velocity: Float, pressure: Float): Float {
        // Combine velocity-based width with pressure
        val velocityWeight = 0.6f
        val pressureWeight = 0.4f

        // Higher velocity = thinner line
        val velocityWidth = maxStrokeWidth - (maxStrokeWidth - minStrokeWidth) *
            (velocity / 10f).coerceIn(0f, 1f)

        // Higher pressure = thicker line
        val pressureWidth = minStrokeWidth + (maxStrokeWidth - minStrokeWidth) *
            pressure.coerceIn(0f, 1f)

        val targetWidth = velocityWidth * velocityWeight + pressureWidth * pressureWeight

        // Smooth transition
        return lastWidth + (targetWidth - lastWidth) * 0.3f
    }

    private fun calculateBounds(): RectF {
        val bounds = RectF()
        val pathBounds = RectF()

        for ((path, _) in paths) {
            path.computeBounds(pathBounds, true)
            bounds.union(pathBounds)
        }

        return bounds
    }

    private data class TimedPoint(
        val x: Float,
        val y: Float,
        val timestamp: Long,
        val pressure: Float
    )
}
