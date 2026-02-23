import UIKit
import PencilKit
import React

@objcMembers
public class SignaturePadView: UIView {

    private var canvasView: PKCanvasView!
    private var redoStack: [PKStroke] = []

    /// Guards against re-entrant delegate callbacks during programmatic drawing changes.
    private var isUpdatingDrawing = false

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

    // Callbacks (RCTDirectEventBlock = NSDictionary? -> Void)
    public var onDrawingChanged: RCTDirectEventBlock?
    public var onSignatureExported: RCTDirectEventBlock?

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
        canvasView.overrideUserInterfaceStyle = .light
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
        isUpdatingDrawing = true
        canvasView.drawing = PKDrawing()
        redoStack.removeAll()
        isUpdatingDrawing = false
        onDrawingChanged?(["hasDrawing": false])
    }

    public func undo() {
        let strokes = canvasView.drawing.strokes
        guard !strokes.isEmpty else { return }

        let lastStroke = strokes.last!
        redoStack.append(lastStroke)

        var newDrawing = canvasView.drawing
        newDrawing.strokes.removeLast()

        isUpdatingDrawing = true
        canvasView.drawing = newDrawing
        isUpdatingDrawing = false

        onDrawingChanged?(["hasDrawing": !newDrawing.strokes.isEmpty])
    }

    public func redo() {
        guard let stroke = redoStack.popLast() else { return }

        var newDrawing = canvasView.drawing
        newDrawing.strokes.append(stroke)

        isUpdatingDrawing = true
        canvasView.drawing = newDrawing
        isUpdatingDrawing = false

        onDrawingChanged?(["hasDrawing": true])
    }

    public func exportSignature(format: String, quality: Int) {
        let drawing = canvasView.drawing
        let drawingBounds = drawing.bounds

        guard !drawingBounds.isEmpty else {
            onSignatureExported?(["imageUrl": ""])
            return
        }

        // Render the drawing to an image with some padding
        let padding: CGFloat = 10
        let renderBounds = drawingBounds.insetBy(dx: -padding, dy: -padding)

        // Force light trait collection so strokes render in their original colors
        let lightTraits = UITraitCollection(userInterfaceStyle: .light)
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2.0
        var image: UIImage?
        lightTraits.performAsCurrent {
            image = drawing.image(from: renderBounds, scale: scale)
        }

        guard let renderedImage = image else {
            onSignatureExported?(["imageUrl": ""])
            return
        }

        // Save to temp directory
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("neurosign", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            onSignatureExported?(["imageUrl": "", "error": error.localizedDescription])
            return
        }

        let ext = format == "png" ? "png" : "jpg"
        let fileName = "\(UUID().uuidString)_signature.\(ext)"
        let fileUrl = tempDir.appendingPathComponent(fileName)

        let compressionQuality = CGFloat(quality) / 100.0
        let data: Data?
        if format == "png" {
            data = renderedImage.pngData()
        } else {
            data = renderedImage.jpegData(compressionQuality: compressionQuality)
        }

        guard let imageData = data else {
            onSignatureExported?(["imageUrl": "", "error": "Failed to encode image"])
            return
        }

        do {
            try imageData.write(to: fileUrl)
            onSignatureExported?(["imageUrl": fileUrl.absoluteString])
        } catch {
            onSignatureExported?(["imageUrl": "", "error": error.localizedDescription])
        }
    }
}

// MARK: - PKCanvasViewDelegate

extension SignaturePadView: PKCanvasViewDelegate {
    public func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isUpdatingDrawing else { return }
        redoStack.removeAll()
        onDrawingChanged?(["hasDrawing": !canvasView.drawing.strokes.isEmpty])
    }
}
