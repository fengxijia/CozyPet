import SwiftUI

struct SpeechBubbleView: View {
    let text: String?
    let visible: Bool

    /// 桌宠浮窗整体 280×340 固定尺寸；sprite 160 + 输入条 + 间距已经吃掉 ~220px，
    /// 留给气泡的高度上限大致 100px。气泡无脑长下去会把桌宠和输入条挤出窗口外
    /// （fixed-size 容器里 VStack 会硬塞），所以这里硬卡个 6 行 ——
    /// 真长文本的完整内容到聊天历史窗里再看，气泡只做"刚说的"快速预览。
    private let lineLimit = 6

    var body: some View {
        Group {
            if visible, let text, !text.isEmpty {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(lineLimit)
                    .truncationMode(.tail)
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
