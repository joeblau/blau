import AVFoundation
import PencilKit
import SwiftUI
import UIKit

struct ContentView: View {
    var mirror: MirrorModel

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            // A single transformable container holds BOTH the video layer and
            // the PencilKit canvas, so pinch-zoom/pan moves them together and
            // annotation strokes stay pixel-aligned with the mirrored window.
            ZoomableMirrorView(mirror: mirror)
                .ignoresSafeArea()

            // Frame-count / status reads live in their own view so the 60fps
            // diagnostic ticks don't re-render the canvas or video reps.
            SearchingOverlay(mirror: mirror)
        }
    }
}

/// The "searching for Pilot" placeholder. Isolated into its own view so the
/// per-frame `frameCount` updates only re-render this text — not the video or
/// PencilKit canvas siblings.
private struct SearchingOverlay: View {
    var mirror: MirrorModel

    var body: some View {
        if mirror.frameCount == 0 {
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text("Searching for Pilot…")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(mirror.statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("Frames received: \(mirror.frameCount)")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                Text(mirror.annotationStatusText)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                Text("If Plotter cannot find Pilot, enable Local Network in Settings on both devices.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                Button {
                    openAppSettings()
                } label: {
                    Label("Open Plotter Settings", systemImage: "gearshape")
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
            }
            .padding(.horizontal, 24)
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Zoomable container

/// Bridges the UIKit ``ZoomableMirrorUIView`` (which owns the video layer, the
/// PencilKit canvas, and the pinch/pan gestures) into SwiftUI.
private struct ZoomableMirrorView: UIViewRepresentable {
    var mirror: MirrorModel

    func makeUIView(context: Context) -> ZoomableMirrorUIView {
        let view = ZoomableMirrorUIView()
        mirror.attach(view.sampleBufferDisplayLayer)
        view.onDrawingChanged = { drawing, contentRect in
            mirror.sendAnnotation(.replaceDrawing(Self.annotationDrawing(
                from: drawing,
                contentRect: contentRect
            )))
        }
        view.onClear = {
            mirror.sendAnnotation(.clear)
        }
        view.videoSize = mirror.videoSize
        return view
    }

    func updateUIView(_ uiView: ZoomableMirrorUIView, context: Context) {
        mirror.attach(uiView.sampleBufferDisplayLayer)
        uiView.videoSize = mirror.videoSize
    }

    /// Maps PencilKit strokes (in the canvas's own, un-zoomed coordinate space)
    /// into normalized [0,1] coordinates relative to the un-zoomed video
    /// content rect, so Pilot maps them back correctly regardless of how the
    /// iPad has locally zoomed/panned.
    private static func annotationDrawing(
        from drawing: PKDrawing,
        contentRect: CGRect
    ) -> AnnotationDrawing {
        let drawRect = contentRect
        let scaleBase = max(1, min(drawRect.width, drawRect.height))
        let strokes = drawing.strokes.compactMap { stroke -> AnnotationStroke? in
            let points = stroke.path.compactMap { point -> AnnotationPoint? in
                guard drawRect.contains(point.location) else { return nil }
                return AnnotationPoint(
                    x: min(1, max(0, (point.location.x - drawRect.minX) / drawRect.width)),
                    y: min(1, max(0, (point.location.y - drawRect.minY) / drawRect.height))
                )
            }
            guard points.count > 1 else { return nil }

            let rgba = stroke.ink.color.rgbaComponents
            let averageWidth = stroke.path.reduce(CGFloat(0)) { partial, point in
                partial + max(point.size.width, point.size.height)
            } / CGFloat(max(1, stroke.path.count))

            return AnnotationStroke(
                color: AnnotationColor(
                    red: rgba.red,
                    green: rgba.green,
                    blue: rgba.blue,
                    alpha: rgba.alpha
                ),
                width: max(1.5, averageWidth) / scaleBase,
                points: points
            )
        }
        return AnnotationDrawing(strokes: strokes)
    }
}

/// Owns the mirrored video layer and the PencilKit canvas inside a single
/// `contentView`, applies a shared affine transform for local pinch-zoom + pan,
/// and reports annotation drawings in normalized coordinates relative to the
/// un-zoomed video content rect.
private final class ZoomableMirrorUIView: UIView, PKCanvasViewDelegate, UIGestureRecognizerDelegate {
    /// Everything that should zoom/pan together lives in here.
    private let contentView = UIView()
    private let videoView = SampleBufferVideoView()
    let canvasView = PKCanvasView()
    private let toolbar = UIStackView()

    private var toolPicker: PKToolPicker?

    var onDrawingChanged: ((PKDrawing, CGRect) -> Void)?
    var onClear: (() -> Void)?

    /// Native size of the mirrored window; used to compute the aspect-fit
    /// content rect that annotations normalize against.
    var videoSize: CGSize = .zero {
        didSet { if videoSize != oldValue { reportDrawing() } }
    }

    // Pinch/pan transform state.
    private var scale: CGFloat = 1.0
    private var translation: CGPoint = .zero
    private let minScale: CGFloat = 1.0
    private let maxScale: CGFloat = 4.0
    private var gestureStartScale: CGFloat = 1.0
    private var gestureStartTranslation: CGPoint = .zero

    var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer {
        videoView.sampleBufferDisplayLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        setupContent()
        setupCanvas()
        setupToolbar()
        setupGestures()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The content view fills us; the affine transform handles zoom/pan.
        contentView.frame = bounds
        videoView.frame = contentView.bounds
        canvasView.frame = contentView.bounds
        applyTransform()
    }

    private func setupContent() {
        addSubview(contentView)
        contentView.backgroundColor = .clear
        contentView.addSubview(videoView)
        contentView.addSubview(canvasView)
    }

    private func setupCanvas() {
        canvasView.delegate = self
        canvasView.drawingPolicy = .anyInput
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.tool = PKInkingTool(.pen, color: .systemRed, width: 4)
        // PencilKit ships its own pan/zoom scroll behaviour; disable it so our
        // gestures drive the shared transform and strokes never desync.
        canvasView.isScrollEnabled = false
        canvasView.minimumZoomScale = 1
        canvasView.maximumZoomScale = 1
        canvasView.becomeFirstResponder()
        installToolPicker(for: canvasView)
    }

    private func installToolPicker(for canvasView: PKCanvasView) {
        let picker = PKToolPicker()
        picker.addObserver(canvasView)
        picker.setVisible(true, forFirstResponder: canvasView)
        toolPicker = picker
    }

    private func setupToolbar() {
        toolbar.axis = .horizontal
        toolbar.spacing = 10
        toolbar.alignment = .center
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.backgroundColor = UIColor.black.withAlphaComponent(0.42)
        toolbar.layer.cornerRadius = 18
        toolbar.isLayoutMarginsRelativeArrangement = true
        toolbar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)

        let undoButton = button(systemName: "arrow.uturn.backward") { [weak self] in
            self?.canvasView.undoManager?.undo()
        }
        let clearButton = button(systemName: "trash") { [weak self] in
            guard let self else { return }
            self.canvasView.drawing = PKDrawing()
            self.onClear?()
        }
        let resetZoomButton = button(systemName: "arrow.up.left.and.arrow.down.right") { [weak self] in
            self?.resetZoom()
        }
        toolbar.addArrangedSubview(resetZoomButton)
        toolbar.addArrangedSubview(undoButton)
        toolbar.addArrangedSubview(clearButton)

        // The toolbar stays fixed (not inside the transformable content view).
        addSubview(toolbar)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -12)
        ])
    }

    private func button(systemName: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.tintColor = .white
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    // MARK: Gestures

    private func setupGestures() {
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        // Two fingers so single-finger drawing on the canvas isn't hijacked.
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        addGestureRecognizer(pinch)
        addGestureRecognizer(pan)
    }

    /// Allow pinch + pan to run simultaneously for a natural zoom/pan feel.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        (gestureRecognizer is UIPinchGestureRecognizer || gestureRecognizer is UIPanGestureRecognizer)
            && (other is UIPinchGestureRecognizer || other is UIPanGestureRecognizer)
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            gestureStartScale = scale
        case .changed:
            scale = clampedScale(gestureStartScale * recognizer.scale)
            translation = clampedTranslation(translation)
            applyTransform()
        case .ended, .cancelled, .failed:
            applyTransform()
        default:
            break
        }
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            gestureStartTranslation = translation
        case .changed:
            let delta = recognizer.translation(in: self)
            translation = clampedTranslation(CGPoint(
                x: gestureStartTranslation.x + delta.x,
                y: gestureStartTranslation.y + delta.y
            ))
            applyTransform()
        case .ended, .cancelled, .failed:
            applyTransform()
        default:
            break
        }
    }

    private func resetZoom() {
        scale = 1
        translation = .zero
        UIView.animate(withDuration: 0.2) { self.applyTransform() }
    }

    private func clampedScale(_ value: CGFloat) -> CGFloat {
        min(maxScale, max(minScale, value))
    }

    /// Clamps the pan so the zoomed content can't be dragged off-screen: the
    /// max offset is half the overflow on each axis.
    private func clampedTranslation(_ value: CGPoint) -> CGPoint {
        let maxX = max(0, (bounds.width * scale - bounds.width) / 2)
        let maxY = max(0, (bounds.height * scale - bounds.height) / 2)
        return CGPoint(
            x: min(maxX, max(-maxX, value.x)),
            y: min(maxY, max(-maxY, value.y))
        )
    }

    private func applyTransform() {
        // Scale about the center, then translate. Both the video and the canvas
        // ride the same transform, so strokes stay aligned with the picture.
        let transform = CGAffineTransform(translationX: translation.x, y: translation.y)
            .scaledBy(x: scale, y: scale)
        contentView.transform = transform
    }

    // MARK: Drawing -> normalized annotation

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        reportDrawing()
    }

    private func reportDrawing() {
        // Report in the canvas's OWN (un-zoomed) coordinate space. The content
        // rect is the aspect-fit video rect within the un-transformed bounds —
        // independent of the local zoom/pan transform — so normalized coords
        // remain stable for Pilot.
        let contentRect = Self.aspectFitRect(contentSize: videoSize, in: canvasView.bounds)
        onDrawingChanged?(canvasView.drawing, contentRect)
    }

    private static func aspectFitRect(contentSize: CGSize, in bounds: CGRect) -> CGRect {
        guard contentSize.width > 0,
              contentSize.height > 0,
              bounds.width > 0,
              bounds.height > 0 else {
            return bounds
        }

        let scale = min(bounds.width / contentSize.width, bounds.height / contentSize.height)
        let width = contentSize.width * scale
        let height = contentSize.height * scale
        return CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
    }
}

private extension UIColor {
    var rgbaComponents: (red: Double, green: Double, blue: Double, alpha: Double) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (Double(red), Double(green), Double(blue), Double(alpha))
    }
}

private final class SampleBufferVideoView: UIView {
    override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }
}
