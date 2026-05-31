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

            VideoMirrorView(mirror: mirror)
                .ignoresSafeArea()

            PencilAnnotationView(
                videoSize: mirror.videoSize,
                hideLocalInk: mirror.localInkHidden,
                onDrawingChanged: { drawing, bounds in
                    mirror.sendAnnotation(.replaceDrawing(Self.annotationDrawing(
                        from: drawing,
                        in: bounds,
                        videoSize: mirror.videoSize
                    )))
                },
                onClear: {
                    mirror.sendAnnotation(.clear)
                },
                onBeginDrawing: {
                    mirror.beginLocalAnnotation()
                }
            )
            .ignoresSafeArea()

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
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
    }

    private static func annotationDrawing(
        from drawing: PKDrawing,
        in bounds: CGRect,
        videoSize: CGSize
    ) -> AnnotationDrawing {
        let drawRect = aspectFitRect(contentSize: videoSize, in: bounds)
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

private struct PencilAnnotationView: UIViewRepresentable {
    var videoSize: CGSize
    /// When true, the local strokes are hidden (Pilot is already rendering
    /// them in the mirror). The canvas stays interactive — `layer.opacity`
    /// hides the ink without blocking touches the way `alpha`/`isHidden` would.
    var hideLocalInk: Bool
    var onDrawingChanged: (PKDrawing, CGRect) -> Void
    var onClear: () -> Void
    var onBeginDrawing: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDrawingChanged: onDrawingChanged, onClear: onClear, onBeginDrawing: onBeginDrawing)
    }

    func makeUIView(context: Context) -> PencilAnnotationUIView {
        let view = PencilAnnotationUIView()
        view.canvasView.delegate = context.coordinator
        view.canvasView.drawingPolicy = .anyInput
        view.canvasView.backgroundColor = .clear
        view.canvasView.isOpaque = false
        view.canvasView.tool = PKInkingTool(.pen, color: .systemRed, width: 4)
        view.canvasView.becomeFirstResponder()
        context.coordinator.canvasView = view.canvasView
        context.coordinator.installToolPicker(for: view.canvasView)
        context.coordinator.onBoundsChanged = { [weak view] in
            guard let view else { return }
            onDrawingChanged(view.canvasView.drawing, view.canvasView.bounds)
        }
        view.onUndo = {
            view.canvasView.undoManager?.undo()
        }
        view.onClear = {
            view.canvasView.drawing = PKDrawing()
            onClear()
        }
        return view
    }

    func updateUIView(_ uiView: PencilAnnotationUIView, context: Context) {
        context.coordinator.onDrawingChanged = onDrawingChanged
        context.coordinator.onClear = onClear
        context.coordinator.onBeginDrawing = onBeginDrawing
        // Hide the ink layer (not the view) so the canvas keeps receiving
        // Pencil/touch input even while the strokes are invisible.
        uiView.canvasView.layer.opacity = hideLocalInk ? 0 : 1
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        weak var canvasView: PKCanvasView?
        var onDrawingChanged: (PKDrawing, CGRect) -> Void
        var onClear: () -> Void
        var onBeginDrawing: () -> Void
        var onBoundsChanged: (() -> Void)?
        private var toolPicker: PKToolPicker?

        init(
            onDrawingChanged: @escaping (PKDrawing, CGRect) -> Void,
            onClear: @escaping () -> Void,
            onBeginDrawing: @escaping () -> Void
        ) {
            self.onDrawingChanged = onDrawingChanged
            self.onClear = onClear
            self.onBeginDrawing = onBeginDrawing
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            onBeginDrawing()
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            onDrawingChanged(canvasView.drawing, canvasView.bounds)
        }

        func installToolPicker(for canvasView: PKCanvasView) {
            let picker = PKToolPicker()
            picker.addObserver(canvasView)
            picker.setVisible(true, forFirstResponder: canvasView)
            toolPicker = picker
        }
    }
}

private final class PencilAnnotationUIView: UIView {
    let canvasView = PKCanvasView()
    private let toolbar = UIStackView()
    var onUndo: (() -> Void)?
    var onClear: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        setupCanvas()
        setupToolbar()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupCanvas() {
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(canvasView)
        NSLayoutConstraint.activate([
            canvasView.leadingAnchor.constraint(equalTo: leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: trailingAnchor),
            canvasView.topAnchor.constraint(equalTo: topAnchor),
            canvasView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
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
            self?.onUndo?()
        }
        let clearButton = button(systemName: "trash") { [weak self] in
            self?.onClear?()
        }
        toolbar.addArrangedSubview(undoButton)
        toolbar.addArrangedSubview(clearButton)

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

private struct VideoMirrorView: UIViewRepresentable {
    var mirror: MirrorModel

    func makeUIView(context: Context) -> SampleBufferVideoView {
        let view = SampleBufferVideoView()
        mirror.attach(view.sampleBufferDisplayLayer)
        return view
    }

    func updateUIView(_ uiView: SampleBufferVideoView, context: Context) {
        mirror.attach(uiView.sampleBufferDisplayLayer)
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
