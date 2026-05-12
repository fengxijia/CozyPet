import SwiftUI

struct SpeechBubbleView: View {
    let text: String?
    let visible: Bool

    var body: some View {
        Group {
            if visible, let text, !text.isEmpty {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.4), lineWidth: 0.5)
                    )
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
