import UIKit
import PencilKit

@objcMembers
public class SignaturePadView: UIView {

    private var canvasView: PKCanvasView!
    private var drawingHistory: [PKDrawing] = []
    private var redoStack: [PKDrawing] = []

    // Props
    public var strokeColor: UIColor = .black {
        didSet { updateTool() }
    }
    public var strokeWidth: CGFloat = 2 {
        didSet { updateTool() }
    }
    public override var backgroundColor: UIColor? {
        didSet {
            canvasView?.backgroundColor = backgroundColor ?? .white
        }
    }
    public var minStrokeWidth: CGFloat = 1
    public var maxStrokeWidth: CGFloat = 5

    // Callbacks
    public var onDrawingChanged: ((_ hasDrawing: Bool) -> Void)?
    public var onSignatureExported: ((_ imageUrl: String) -> Void)?

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupCanvas()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupCanvas()
    }

    private func setupCanvas() {
        canvasView = PKCanvasView(frame: bounds)
        canvasView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvasView.backgroundColor = .white
        canvasView.drawingPolicy = .anyInput
        canvasView.delegate = self

        updateTool()

        addSubview(canvasView)
    }

    private func updateTool() {
        let ink = PKInkingTool(.pen, color: strokeColor, width: strokeWidth)
        canvasView.tool = ink
    }

    // MARK: - Commands

    public func clear() {
        drawingHistory.append(canvasView.drawing)
        canvasView.drawing = PKDrawing()
        redoStack.removeAll()
        onDrawingChanged?(false)
    }

    public func undo() {
        guard !canvasView.drawing.strokes.isEmpty else { return }
        var current = canvasView.drawing
        let lastStroke = current.strokes.removeLast()
        drawingHistory.append(canvasView.drawing)

        // Create a drawing without the last stroke
        var newDrawing = PKDrawing()
        if !current.strokes.isEmpty {
            newDrawing = current
        }
        canvasView.drawing = newDrawing

        // Store for redo
        var redoDrawing = canvasView.drawing
        redoDrawing.strokes.append(lastStroke)
        redoStack.append(redoDrawing)

        onDrawingChanged?(!canvasView.drawing.strokes.isEmpty)
    }

    public func redo() {
        guard let redoDrawing = redoStack.popLast() else { return }
        drawingHistory.append(canvasView.drawing)
        canvasView.drawing = redoDrawing
        onDrawingChanged?(!canvasView.drawing.strokes.isEmpty)
    }

    public func exportSignature(format: String, quality: Int) {
        let drawing = canvasView.drawing
        let bounds = drawing.bounds

        guard !bounds.isEmpty else {
            onSignatureExported?("")
            return
        }

        // Render the drawing to an image with some padding
        let padding: CGFloat = 10
        let renderBounds = bounds.insetBy(dx: -padding, dy: -padding)
        let image = drawing.image(from: renderBounds, scale: UIScreen.main.scale)

        // Save to temp directory
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("neurosign", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let fileName = "\(UUID().uuidString)_signature.\(format == "png" ? "png" : "png")"
        let fileUrl = tempDir.appendingPathComponent(fileName)

        let compressionQuality = CGFloat(quality) / 100.0
        if let data = format == "png"
            ? image.pngData()
            : image.jpegData(compressionQuality: compressionQuality)
        {
            try? data.write(to: fileUrl)
            onSignatureExported?(fileUrl.absoluteString)
        }
    }
}

// MARK: - PKCanvasViewDelegate

extension SignaturePadView: PKCanvasViewDelegate {
    public func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        redoStack.removeAll()
        onDrawingChanged?(!canvasView.drawing.strokes.isEmpty)
    }
}
