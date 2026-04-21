import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Custom tooltip overlay (bypasses SwiftUI's slow `.help()`)

/// Attach to any view to show a custom popover tooltip on hover.
/// Shows after a short delay, disappears instantly on mouse-exit.
public struct TooltipModifier: ViewModifier {
    let text: String
    let delay: Double

    @State private var isHovering = false
    @State private var showTip = false
    @State private var hoverTask: Task<Void, Never>?

    public func body(content: Content) -> some View {
        content
            .onHover { hovering in
                isHovering = hovering
                hoverTask?.cancel()
                if hovering {
                    hoverTask = Task {
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        if !Task.isCancelled && isHovering {
                            await MainActor.run {
                                withAnimation(.easeInOut(duration: 0.12)) {
                                    showTip = true
                                }
                            }
                        }
                    }
                } else {
                    withAnimation(.easeInOut(duration: 0.1)) { showTip = false }
                }
            }
            .overlay(alignment: .bottom) {
                if showTip {
                    TooltipBubble(text: text)
                        .fixedSize()
                        .offset(y: 34)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        .zIndex(10000)
                        .allowsHitTesting(false)
                }
            }
    }
}

public struct TooltipBubble: View {
    let text: String

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(text.split(separator: "\n").enumerated()), id: \.offset) { (idx, line) in
                if idx == 0 {
                    // Title
                    Text(String(line))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                } else {
                    Text(String(line))
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.85))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 2)
        )
        .frame(maxWidth: 320, alignment: .leading)
    }
}

public extension View {
    /// Show a custom fast-appearing tooltip on hover.
    /// Use this instead of `.help()` which is slow and unreliable inside toolbars.
    func tooltip(_ text: String, delay: Double = 0.4) -> some View {
        modifier(TooltipModifier(text: text, delay: delay))
    }
}
