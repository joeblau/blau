import AppKit
import SwiftUI

struct InkStroke {
    var color: NSColor
    var width: CGFloat
    var points: [CGPoint]
}

@MainActor
@Observable
final class InkModel {
    var strokes: [InkStroke] = []
    var color: NSColor = .systemRed
    var width: CGFloat = 3
    var isEraser = false

    func undo() { if !strokes.isEmpty { strokes.removeLast() } }
    func clear() { strokes.removeAll() }
}

/// Freehand annotation layer drawn over the active pane (terminal/browser/
/// device). Used in place of PencilKit's `PKCanvasView`, which is iOS/Catalyst
/// only and unavailable in this native macOS app. Strokes clear when dismissed.
struct InkOverlay: View {
    @Binding var isActive: Bool
    @State private var model = InkModel()

    private let palette: [NSColor] = [.systemRed, .systemOrange, .systemYellow,
                                      .systemGreen, .systemBlue, .white]

    var body: some View {
        ZStack(alignment: .top) {
            InkCanvas(model: model)
            toolbar.padding(.top, 14)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
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
            toolButton("arrow.uturn.backward", disabled: model.strokes.isEmpty) { model.undo() }
            toolButton("trash", disabled: model.strokes.isEmpty) { model.clear() }

            Divider().frame(height: 18)

            Button("Done") { isActive = false }
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

/// AppKit canvas capturing freehand strokes and rendering them transparently
/// on top of whatever pane is behind it.
private struct InkCanvas: NSViewRepresentable {
    var model: InkModel

    func makeNSView(context: Context) -> InkCanvasNSView {
        let view = InkCanvasNSView()
        view.model = model
        return view
    }

    func updateNSView(_ nsView: InkCanvasNSView, context: Context) {
        nsView.model = model
        nsView.needsDisplay = true
    }
}

final class InkCanvasNSView: NSView {
    weak var model: InkModel?
    private var current: InkStroke?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // Capture every click so the pane underneath stays untouched while drawing.
    override func hitTest(_ point: NSPoint) -> NSView? { self }

    override func mouseDown(with event: NSEvent) {
        guard let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        if model.isEraser {
            erase(near: point)
        } else {
            current = InkStroke(color: model.color, width: model.width, points: [point])
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        if model.isEraser {
            erase(near: point)
        } else {
            current?.points.append(point)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let stroke = current, stroke.points.count > 1 {
            model?.strokes.append(stroke)
        }
        current = nil
        needsDisplay = true
    }

    private func erase(near point: CGPoint) {
        model?.strokes.removeAll { stroke in
            stroke.points.contains { hypot($0.x - point.x, $0.y - point.y) < max(14, stroke.width * 3) }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        var all = model?.strokes ?? []
        if let current { all.append(current) }
        for stroke in all where stroke.points.count > 1 {
            let path = NSBezierPath()
            path.lineWidth = stroke.width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: stroke.points[0])
            for point in stroke.points.dropFirst() { path.line(to: point) }
            stroke.color.setStroke()
            path.stroke()
        }
    }
}
