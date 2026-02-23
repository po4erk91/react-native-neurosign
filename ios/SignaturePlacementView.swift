import UIKit
import React

@objcMembers
public class SignaturePlacementView: UIView, UIGestureRecognizerDelegate {

    // Subviews
    private let pdfImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.clipsToBounds = true
        return iv
    }()

    private let signatureImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleToFill
        iv.isUserInteractionEnabled = false
        iv.frame = .zero
        return iv
    }()

    // Dashed border layer
    private let dashedBorderLayer = CAShapeLayer()

    // Corner handle layers (top-left and bottom-right)
    private let topLeftCornerLayer = CAShapeLayer()
    private let bottomRightCornerLayer = CAShapeLayer()

    // Configurable border/corner values (in pt)
    private var _borderColorUI: UIColor = UIColor(red: 233/255, green: 69/255, blue: 96/255, alpha: 1)
    private var _borderWidthPt: CGFloat = 2
    private var _borderPaddingPt: CGFloat = 0
    private var _cornerSizePt: CGFloat = 14
    private var _cornerWidthPt: CGFloat = 3
    private var _borderRadiusPt: CGFloat = 0

    // PDF state
    private var pdfDocument: CGPDFDocument?
    private var currentPageIndex: Int = 0
    private var totalPageCount: Int = 0
    private var needsInitialPosition: Bool = true

    // Signature position/size in view coordinates
    private var sigX: CGFloat = 0
    private var sigY: CGFloat = 0
    private var sigWidth: CGFloat = 150
    private var sigHeight: CGFloat = 50
    private var sigAspectRatio: CGFloat = 3

    // PDF display rect within this view (aspect-fit)
    private var pdfDisplayRect: CGRect = .zero

    // Default position (normalized 0-1, -1 = center)
    private var _defaultPositionX: CGFloat = -1
    private var _defaultPositionY: CGFloat = -1

    // Drag state
    private var dragStartPoint: CGPoint = .zero
    private var dragStartSigPos: CGPoint = .zero

    // Pinch state
    private var pinchStartWidth: CGFloat = 0
    private var pinchStartCenter: CGPoint = .zero

    // RCT event blocks
    public var onPlacementConfirmed: RCTDirectEventBlock?
    public var onPageCount: RCTDirectEventBlock?

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .clear
        clipsToBounds = true

        addSubview(pdfImageView)
        addSubview(signatureImageView)

        // Add overlay layers above everything
        configureLayers()
        layer.addSublayer(dashedBorderLayer)
        layer.addSublayer(topLeftCornerLayer)
        layer.addSublayer(bottomRightCornerLayer)

        // Gesture recognizers
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.delegate = self
        addGestureRecognizer(panGesture)

        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinchGesture.delegate = self
        addGestureRecognizer(pinchGesture)
    }

    // MARK: - UIGestureRecognizerDelegate

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        return true
    }

    /// Prevent React Native's touch handler from blocking our pinch/pan gestures
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // If our gesture is pinch or pan, don't let RN's touch handler require us to fail
        return false
    }

    // Disable React Native touch interception on this view
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        disableRCTTouchHandler()
    }

    private func disableRCTTouchHandler() {
        // Walk up responder chain to find RCTTouchHandler and make it yield to our gestures
        var current: UIView? = self
        while let view = current {
            for recognizer in view.gestureRecognizers ?? [] {
                let name = String(describing: type(of: recognizer))
                if name.contains("RCTTouchHandler") || name.contains("RCTRootContentView") {
                    for myGR in gestureRecognizers ?? [] {
                        recognizer.require(toFail: myGR)
                    }
                }
            }
            current = view.superview
        }
    }

    // MARK: - Props

    public var pdfUrl: NSString? {
        didSet {
            guard let url = pdfUrl as String? else { return }
            loadPdf(url)
        }
    }

    public var signatureImageUrl: NSString? {
        didSet {
            guard let url = signatureImageUrl as String? else { return }
            loadSignatureImage(url)
        }
    }

    public var pageIndex: NSInteger = 0 {
        didSet {
            if pageIndex != currentPageIndex {
                currentPageIndex = pageIndex
                needsInitialPosition = true
                renderCurrentPage()
            }
        }
    }

    public var defaultPositionX: CGFloat = -1 {
        didSet { _defaultPositionX = defaultPositionX }
    }

    public var defaultPositionY: CGFloat = -1 {
        didSet { _defaultPositionY = defaultPositionY }
    }

    public var placeholderBackgroundColor: NSString? {
        didSet {
            guard let hex = placeholderBackgroundColor as String? else { return }
            backgroundColor = UIColor(hexString: hex) ?? backgroundColor
        }
    }

    public var sigBorderColor: NSString? {
        didSet {
            guard let hex = sigBorderColor as String? else { return }
            _borderColorUI = UIColor(hexString: hex) ?? _borderColorUI
            configureLayers()
            updateOverlayLayers()
        }
    }

    public var sigBorderWidth: CGFloat = 2 {
        didSet {
            _borderWidthPt = sigBorderWidth
            configureLayers()
            updateOverlayLayers()
        }
    }

    public var sigBorderPadding: CGFloat = 0 {
        didSet {
            _borderPaddingPt = sigBorderPadding
            updateOverlayLayers()
        }
    }

    public var sigCornerSize: CGFloat = 14 {
        didSet {
            _cornerSizePt = sigCornerSize
            updateOverlayLayers()
        }
    }

    public var sigCornerWidth: CGFloat = 3 {
        didSet {
            _cornerWidthPt = sigCornerWidth
            configureLayers()
            updateOverlayLayers()
        }
    }

    public var sigBorderRadius: CGFloat = 0 {
        didSet {
            _borderRadiusPt = sigBorderRadius
            updateOverlayLayers()
        }
    }

    private func configureLayers() {
        let cgColor = _borderColorUI.cgColor

        dashedBorderLayer.strokeColor = cgColor
        dashedBorderLayer.fillColor = nil
        dashedBorderLayer.lineWidth = _borderWidthPt
        dashedBorderLayer.lineDashPattern = [8, 6]

        topLeftCornerLayer.strokeColor = cgColor
        topLeftCornerLayer.fillColor = nil
        topLeftCornerLayer.lineWidth = _cornerWidthPt
        topLeftCornerLayer.lineCap = .round

        bottomRightCornerLayer.strokeColor = cgColor
        bottomRightCornerLayer.fillColor = nil
        bottomRightCornerLayer.lineWidth = _cornerWidthPt
        bottomRightCornerLayer.lineCap = .round
    }

    // MARK: - Commands

    public func confirm() {
        guard pdfDisplayRect.width > 0, pdfDisplayRect.height > 0 else { return }

        let normalizedX = Double((sigX - pdfDisplayRect.origin.x) / pdfDisplayRect.width)
        let normalizedY = Double((sigY - pdfDisplayRect.origin.y) / pdfDisplayRect.height)
        let normalizedW = Double(sigWidth / pdfDisplayRect.width)
        let normalizedH = Double(sigHeight / pdfDisplayRect.height)

        let data: [String: Any] = [
            "pageIndex": currentPageIndex,
            "x": max(0, min(1.0 - normalizedW, normalizedX)),
            "y": max(0, min(1.0 - normalizedH, normalizedY)),
            "width": min(1.0, normalizedW),
            "height": min(1.0, normalizedH)
        ]
        onPlacementConfirmed?(data)
    }

    public func reset() {
        needsInitialPosition = true
        positionSignatureDefault()
        needsInitialPosition = false
        updateSignatureLayout()
    }

    // MARK: - Gestures

    private var panActive = false

    private func isTouchInsideSignature(_ point: CGPoint) -> Bool {
        let sigRect = CGRect(x: sigX, y: sigY, width: sigWidth, height: sigHeight)
        return sigRect.contains(point)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            let point = gesture.location(in: self)
            panActive = isTouchInsideSignature(point)
            if panActive {
                dragStartPoint = point
                dragStartSigPos = CGPoint(x: sigX, y: sigY)
            }
        case .changed:
            guard panActive else { return }
            let current = gesture.location(in: self)
            let dx = current.x - dragStartPoint.x
            let dy = current.y - dragStartPoint.y
            sigX = clampX(dragStartSigPos.x + dx)
            sigY = clampY(dragStartSigPos.y + dy)
            updateSignatureLayout()
        default:
            panActive = false
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchStartWidth = sigWidth
            pinchStartCenter = CGPoint(x: sigX + sigWidth / 2, y: sigY + sigHeight / 2)
        case .changed:
            let maxWidth = pdfDisplayRect.width * 0.9
            let newWidth = max(60, min(maxWidth, pinchStartWidth * gesture.scale))
            let newHeight = newWidth / sigAspectRatio

            // Keep center stable
            let newX = pinchStartCenter.x - newWidth / 2
            let newY = pinchStartCenter.y - newHeight / 2

            sigWidth = newWidth
            sigHeight = newHeight
            sigX = clampX(newX)
            sigY = clampY(newY)
            updateSignatureLayout()
        default:
            break
        }
    }

    // MARK: - Layout

    private var lastRenderedBounds: CGSize = .zero

    public override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        if size.width > 0 && size.height > 0 && size != lastRenderedBounds {
            lastRenderedBounds = size
            renderCurrentPage()
        }
    }

    private func updateSignatureLayout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        signatureImageView.frame = CGRect(x: sigX, y: sigY, width: sigWidth, height: sigHeight)
        CATransaction.commit()
        updateOverlayLayers()
    }

    private func updateOverlayLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let p = _borderPaddingPt
        let rect = CGRect(
            x: sigX - p, y: sigY - p,
            width: sigWidth + p * 2, height: sigHeight + p * 2
        )

        // Dashed border (with optional rounded corners)
        let borderPath: UIBezierPath
        if _borderRadiusPt > 0 {
            borderPath = UIBezierPath(roundedRect: rect, cornerRadius: _borderRadiusPt)
        } else {
            borderPath = UIBezierPath(rect: rect)
        }
        dashedBorderLayer.path = borderPath.cgPath

        // Top-left corner
        let cl = _cornerSizePt
        let tlPath = UIBezierPath()
        tlPath.move(to: CGPoint(x: rect.minX, y: rect.minY + cl))
        tlPath.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        tlPath.addLine(to: CGPoint(x: rect.minX + cl, y: rect.minY))
        topLeftCornerLayer.path = tlPath.cgPath

        // Bottom-right corner
        let brPath = UIBezierPath()
        brPath.move(to: CGPoint(x: rect.maxX, y: rect.maxY - cl))
        brPath.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        brPath.addLine(to: CGPoint(x: rect.maxX - cl, y: rect.maxY))
        bottomRightCornerLayer.path = brPath.cgPath

        CATransaction.commit()
    }

    // MARK: - Clamping

    private func clampX(_ x: CGFloat) -> CGFloat {
        let minX = pdfDisplayRect.origin.x
        let maxX = pdfDisplayRect.maxX - sigWidth
        return max(minX, min(max(maxX, minX), x))
    }

    private func clampY(_ y: CGFloat) -> CGFloat {
        let minY = pdfDisplayRect.origin.y
        let maxY = pdfDisplayRect.maxY - sigHeight
        return max(minY, min(max(maxY, minY), y))
    }

    // MARK: - PDF Loading

    private func loadPdf(_ urlString: String) {
        var fileUrl: URL?
        if urlString.hasPrefix("file://") {
            fileUrl = URL(string: urlString)
        } else if urlString.hasPrefix("/") {
            fileUrl = URL(fileURLWithPath: urlString)
        } else {
            fileUrl = URL(string: urlString)
        }

        guard let url = fileUrl else { return }
        guard let document = CGPDFDocument(url as CFURL) else { return }

        pdfDocument = document
        totalPageCount = document.numberOfPages
        needsInitialPosition = true

        renderCurrentPage()

        // Defer onPageCount to ensure React callback props are set
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onPageCount?(["count": self.totalPageCount])
        }
    }

    private func renderCurrentPage() {
        guard let document = pdfDocument else { return }
        let pageNumber = currentPageIndex + 1
        guard pageNumber >= 1, pageNumber <= document.numberOfPages else { return }
        guard let page = document.page(at: pageNumber) else { return }
        guard bounds.width > 0, bounds.height > 0 else { return }

        let pageRect = page.getBoxRect(.mediaBox)
        let pageWidth = pageRect.width
        let pageHeight = pageRect.height

        let viewW = bounds.width
        let viewH = bounds.height
        let pdfAspect = pageWidth / pageHeight
        let viewAspect = viewW / viewH

        let displayW: CGFloat
        let displayH: CGFloat
        let displayX: CGFloat
        let displayY: CGFloat

        if pdfAspect > viewAspect {
            displayW = viewW
            displayH = viewW / pdfAspect
            displayX = 0
            displayY = (viewH - displayH) / 2
        } else {
            displayH = viewH
            displayW = viewH * pdfAspect
            displayX = (viewW - displayW) / 2
            displayY = 0
        }

        pdfDisplayRect = CGRect(x: displayX, y: displayY, width: displayW, height: displayH)

        let scale = UIScreen.main.scale
        let renderSize = CGSize(width: displayW * scale, height: displayH * scale)
        let renderer = UIGraphicsImageRenderer(size: renderSize)
        let image = renderer.image { ctx in
            let context = ctx.cgContext
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(origin: .zero, size: renderSize))

            context.translateBy(x: 0, y: renderSize.height)
            context.scaleBy(x: 1, y: -1)

            let scaleX = renderSize.width / pageWidth
            let scaleY = renderSize.height / pageHeight
            context.scaleBy(x: scaleX, y: scaleY)

            context.drawPDFPage(page)
        }

        pdfImageView.image = image
        pdfImageView.frame = pdfDisplayRect

        if needsInitialPosition {
            positionSignatureDefault()
            needsInitialPosition = false
        }
        // Re-clamp in case display rect changed on resize
        sigX = clampX(sigX)
        sigY = clampY(sigY)
        updateSignatureLayout()
    }

    private func positionSignatureDefault() {
        guard pdfDisplayRect.width > 0 else { return }

        sigWidth = pdfDisplayRect.width * 0.25
        sigHeight = sigWidth / sigAspectRatio

        if _defaultPositionX >= 0, _defaultPositionY >= 0 {
            sigX = pdfDisplayRect.origin.x + _defaultPositionX * pdfDisplayRect.width
            sigY = pdfDisplayRect.origin.y + _defaultPositionY * pdfDisplayRect.height
        } else {
            sigX = pdfDisplayRect.origin.x + (pdfDisplayRect.width - sigWidth) / 2
            sigY = pdfDisplayRect.origin.y + (pdfDisplayRect.height - sigHeight) / 2
        }

        sigX = clampX(sigX)
        sigY = clampY(sigY)
    }

    // MARK: - Signature image loading

    private func loadSignatureImage(_ urlString: String) {
        var fileUrl: URL?
        if urlString.hasPrefix("file://") {
            fileUrl = URL(string: urlString)
        } else if urlString.hasPrefix("/") {
            fileUrl = URL(fileURLWithPath: urlString)
        } else {
            fileUrl = URL(string: urlString)
        }

        guard let url = fileUrl,
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return }

        sigAspectRatio = image.size.width / image.size.height
        signatureImageView.image = image

        if pdfDisplayRect.width > 0 {
            sigHeight = sigWidth / sigAspectRatio
            updateSignatureLayout()
        }
    }
}

// MARK: - UIColor hex string helper

private extension UIColor {
    convenience init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let intVal = UInt64(hex, radix: 16) else { return nil }
        let r = CGFloat((intVal >> 16) & 0xFF) / 255.0
        let g = CGFloat((intVal >> 8) & 0xFF) / 255.0
        let b = CGFloat(intVal & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}
