import SwiftUI

struct TranscriptionOverlay: View {
    let service: TranscriptionService

    var body: some View {
        VStack {
            Spacer()
            if !service.isModelLoaded && !service.modelLoadingProgress.isEmpty {
                label(service.modelLoadingProgress, style: .secondary)
            } else if service.finalText.isEmpty && service.partialText.isEmpty {
                label("Listening...", style: .secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        if !service.finalText.isEmpty {
                            Text(service.finalText)
                                .foregroundStyle(.primary)
                        }
                        if !service.partialText.isEmpty {
                            Text(service.partialText)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                .defaultScrollAnchor(.trailing)
                .frame(maxWidth: 600)
                .background(.ultraThinMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            }
        }
        .padding(.bottom, 16)
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.2), value: service.finalText)
        .animation(.easeInOut(duration: 0.2), value: service.partialText)
    }

    private func label(_ text: String, style: some ShapeStyle) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(style)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}
