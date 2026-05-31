import AppKit
import SwiftUI

/// A freehand stroke stored in NORMALIZED [0,1] coordinates relative to the
/// overlay bounds. Normalized storage means strokes render correctly at any
/// window size (no drift on resize) and that locally-drawn strokes and strokes
/// pushed from Plotter live in the same coordinate space. `width` is a fraction
/// of the smaller bounds dimension.
struct InkStroke {
    var color: NSColor
    var width: CGFloat
    var points: [CGPoint]
}

/// Single merged ink model for Pilot. Holds Pilot's own strokes AND strokes
/// pushed from Plotter in one ordered undo stack, so the palette's undo/clear —
/// and Plotter's undo/clear — all act on the same stack.
@MainActor
@Observable
final class InkModel {
    private(set) var strokes: [InkStroke] = []
    private(set) var changeID = 0
    var color: NSColor = .systemRed
    var width: CGFloat = 3
    var isEraser = false

    var hasInk: Bool { !strokes.isEmpty }

    func append(_ stroke: InkStroke) {
        strokes.append(stroke)
        changeID += 1
    }

    /// Undo the most recent stroke (local or from Plotter — one merged stack).
    func undo() {
        guard !strokes.isEmpty else { return }
        strokes.removeLast()
        changeID += 1
    }

    /// Clear the whole merged canvas.
    func clear() {
        guard !strokes.isEmpty else { return }
        strokes.removeAll()
        changeID += 1
    }

    /// Erase strokes whose path passes within `radius` of a normalized point.
    func erase(nearNormalized point: CGPoint, radius: CGFloat) {
        let before = strokes.count
        strokes.removeAll { stroke in
            stroke.points.contains { hypot($0.x - point.x, $0.y - point.y) < radius }
        }
        if strokes.count != before { changeID += 1 }
    }

    /// Applies an annotation message from Plotter to the merged stack. Plotter
    /// sends one `addStroke` per line (each its own undo entry); `clear`/`undo`
    /// act on the whole merged stack just like the local palette buttons.
    func handle(_ message: AnnotationMessage) {
        switch message {
        case .addStroke(let stroke):
            append(Self.makeStroke(from: stroke))
        case .clear:
            clear()
        case .undo:
            undo()
        case .replaceDrawing(let drawing):
            // Legacy / resync: replace the whole stack.
            strokes = drawing.strokes.map(Self.makeStroke)
            changeID += 1
        }
    }

    private static func makeStroke(from stroke: AnnotationStroke) -> InkStroke {
        InkStroke(
            color: NSColor(
                calibratedRed: CGFloat(stroke.color.red),
                green: CGFloat(stroke.color.green),
                blue: CGFloat(stroke.color.blue),
                alpha: CGFloat(stroke.color.alpha)
            ),
            width: CGFloat(stroke.width),
            points: stroke.points.map { CGPoint(x: $0.x, y: $0.y) }
        )
    }
}

/// Freehand annotation layer over the Pilot window. Renders the merged ink
/// (local + Plotter) at all times when there's ink; captures mouse input only
/// while `isActive` (the ⇧⌘D draw mode) so the panes underneath stay usable
/// otherwise. The toolbar's undo/clear act on the merged stack, so Pilot can
/// undo/delete strokes that came from Plotter.
struct InkOverlay: View {
    var model: InkModel
    @Binding var isActive: Bool

    private let palette: [NSColor] = [.systemRed, .systemOrange, .systemYellow,
                                      .systemGreen, .systemBlue, .white]

    var body: some View {
        ZStack(alignment: .top) {
            // Reading `changeID` here makes the view re-evaluate (and the canvas
            // repaint) whenever the merged stack changes — including strokes
            // pushed from Plotter while `hasInk` stays true.
            InkCanvas(model: model, isInteractive: isActive, changeID: model.changeID)
            toolbar.padding(.top, 14)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            if isActive {
                ForEach(palette.indices, id: \.self) { index in
                    let swatch = palette[index]
                    Circle()
                        .fill(Color(nsColor: swatch))
                        .frame(width: 18, height: 18)
                        .overlay {
                            Circle().strokeBorder(
                                .primary.opacity(!model.isEraser && model.color == swatch ? 0.9 : 0),
                                lineWidth: 2
                            )
                        }
                        .contentShape(Circle())
                        .onTapGesture {
                            model.color = swatch
                            model.isEraser = false
                        }
                }

                Divider().frame(height: 18)

                toolButton("eraser", active: model.isEraser) { model.isEraser.toggle() }
            }

            toolButton("arrow.uturn.backward", disabled: !model.hasInk) { model.undo() }
            toolButton("trash", disabled: !model.hasInk) { model.clear() }

            Divider().frame(height: 18)

            Button(isActive ? "Done" : "Draw") { isActive.toggle() }
                .buttonStyle(.plain)
                .scaledFont(size: 12, weight: .semibold)
                .padding(.horizontal, 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator.opacity(0.4), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }

    private func toolButton(_ symbol: String, active: Bool = false,
                            disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .scaledFont(size: 13, weight: .medium)
                .foregroundStyle(active ? Color.accentColor : .primary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

/// AppKit canvas that renders the merged ink and, while interactive, captures
/// freehand strokes. Everything is stored normalized; the in-progress stroke is
/// kept in view coordinates and normalized on mouse-up.
private struct InkCanvas: NSViewRepresentable {
    var model: InkModel
    var isInteractive: Bool
    /// Bump to force a repaint when the merged stack changes.
    var changeID: Int

    func makeNSView(context: Context) -> InkCanvasNSView {
        let view = InkCanvasNSView()
        view.model = model
        view.isInteractive = isInteractive
        return view
    }

    func updateNSView(_ nsView: InkCanvasNSView, context: Context) {
        nsView.model = model
        nsView.isInteractive = isInteractive
        nsView.needsDisplay = true
        nsView.refreshCursor()
    }
}

final class InkCanvasNSView: NSView {
    weak var model: InkModel?
    /// When false the canvas only renders; mouse events pass through to the
    /// panes underneath.
    var isInteractive = false {
        didSet { if isInteractive != oldValue { window?.invalidateCursorRects(for: self) } }
    }
    /// In-progress stroke, in view coordinates (normalized on mouse-up).
    private var currentPoints: [CGPoint] = []
    private var isMouseInside = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // Capture clicks only while drawing; otherwise let the pane underneath work.
    override func hitTest(_ point: NSPoint) -> NSView? { isInteractive ? self : nil }

    // MARK: - Geometry

    private var minDimension: CGFloat { max(1, min(bounds.width, bounds.height)) }
    private func normalize(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x / max(1, bounds.width), y: p.y / max(1, bounds.height))
    }
    private func denormalize(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * bounds.width, y: p.y * bounds.height)
    }

    // MARK: - Cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited],
            owner: self
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        if isInteractive { currentCursor().set() }
    }

    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
        if isInteractive { currentCursor().set() }
    }

    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
    }

    func refreshCursor() {
        if isInteractive, isMouseInside { currentCursor().set() }
    }

    private func currentCursor() -> NSCursor {
        guard let model else { return .crosshair }
        return model.isEraser
            ? Self.makeCursor(symbol: "eraser.fill", color: .white, centerHotspot: true)
            : Self.makeCursor(symbol: "pencil", color: model.color, centerHotspot: false)
    }

    /// Builds an NSCursor from an SF Symbol, tinted to the ink color with a dark
    /// halo so it stays visible over any pane.
    private static func makeCursor(symbol: String, color: NSColor, centerHotspot: Bool) -> NSCursor {
        let config = NSImage.SymbolConfiguration(pointSize: 28, weight: .medium)
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return .crosshair }

        let size = base.size
        let tinted = NSImage(size: size)
        tinted.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: size))
        color.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        tinted.unlockFocus()

        let pad: CGFloat = 3
        let canvasSize = NSSize(width: size.width + pad * 2, height: size.height + pad * 2)
        let image = NSImage(size: canvasSize)
        image.lockFocus()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.7)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = .zero
        shadow.set()
        tinted.draw(in: NSRect(x: pad, y: pad, width: size.width, height: size.height))
        image.unlockFocus()

        let hotSpot = centerHotspot
            ? NSPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            : NSPoint(x: pad + 1, y: canvasSize.height - pad - 1)
        return NSCursor(image: image, hotSpot: hotSpot)
    }

    // MARK: - Drawing input (only while interactive; hitTest gates this)

    override func mouseDown(with event: NSEvent) {
        guard let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        if model.isEraser {
            eraseNear(point)
        } else {
            currentPoints = [point]
        }
        needsDisplay = true
        currentCursor().set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        if model.isEraser {
            eraseNear(point)
        } else {
            currentPoints.append(point)
        }
        needsDisplay = true
        currentCursor().set()
    }

    override func mouseUp(with event: NSEvent) {
        if let model, currentPoints.count > 1 {
            // Normalize the finished stroke into the merged stack.
            let stroke = InkStroke(
                color: model.color,
                width: model.width / minDimension,
                points: currentPoints.map(normalize)
            )
            model.append(stroke)
        }
        currentPoints = []
        needsDisplay = true
    }

    private func eraseNear(_ point: CGPoint) {
        guard let model else { return }
        let radius = max(14, model.width * 3) / minDimension
        model.erase(nearNormalized: normalize(point), radius: radius)
    }

    // MARK: - Render (always, including non-interactive)

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let minDim = minDimension

        for stroke in model?.strokes ?? [] where stroke.points.count > 1 {
            let path = NSBezierPath()
            path.lineWidth = max(1, stroke.width * minDim)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: denormalize(stroke.points[0]))
            for point in stroke.points.dropFirst() { path.line(to: denormalize(point)) }
            stroke.color.setStroke()
            path.stroke()
        }

        // The in-progress stroke is still in view coordinates.
        if currentPoints.count > 1, let model {
            let path = NSBezierPath()
            path.lineWidth = model.width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: currentPoints[0])
            for point in currentPoints.dropFirst() { path.line(to: point) }
            model.color.setStroke()
            path.stroke()
        }
    }
}
