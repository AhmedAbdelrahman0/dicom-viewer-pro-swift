import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Tooltip preference (bubbles hovered tooltip info up to the root view)

struct TooltipPayload: Equatable, Sendable {
    let id = UUID()
    var text: String
    /// Source anchor frame in the GLOBAL coordinate space of the root view.
    var sourceFrame: CGRect
}

struct TooltipPreferenceKey: PreferenceKey {
    static let defaultValue: TooltipPayload? = nil
    static func reduce(value: inout TooltipPayload?, nextValue: () -> TooltipPayload?) {
        // Last writer wins — since only one tooltip is hovered at a time,
        // this naturally tracks the active one.
        if let next = nextValue() { value = next }
    }
}

// MARK: - Tooltip modifier (attached to buttons)

struct TooltipModifier: ViewModifier {
    let text: String
    let delay: Double

    @State private var isHovering = false
    @State private var isActive = false      // delay elapsed → show
    @State private var sourceFrame: CGRect = .zero
    @State private var hoverTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear {
                            sourceFrame = geo.frame(in: .named("rootSpace"))
                        }
                        .onChange(of: geo.frame(in: .named("rootSpace"))) { _, newFrame in
                            sourceFrame = newFrame
                        }
                }
            )
            .onHover { hovering in
                isHovering = hovering
                hoverTask?.cancel()
                if hovering {
                    hoverTask = Task { [delay] in
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        if !Task.isCancelled && isHovering {
                            await MainActor.run { isActive = true }
                        }
                    }
                } else {
                    isActive = false
                }
            }
            .preference(
                key: TooltipPreferenceKey.self,
                value: isActive ? TooltipPayload(text: text, sourceFrame: sourceFrame) : nil
            )
    }
}

// MARK: - Root tooltip host (attach to the topmost view)

/// Attach this to the outermost view of your UI. It listens for tooltip
/// preferences from any descendant `.tooltip(…)` modifier and renders a
/// single bubble on top of everything, clamped to the window's bounds.
struct TooltipHost: ViewModifier {
    @State private var payload: TooltipPayload? = nil

    func body(content: Content) -> some View {
        GeometryReader { rootGeo in
            content
                .coordinateSpace(name: "rootSpace")
                .onPreferenceChange(TooltipPreferenceKey.self) { new in
                    payload = new
                }
                .overlay(alignment: .topLeading) {
                    if let p = payload {
                        TooltipOverlay(payload: p, rootSize: rootGeo.size)
                            .id(p.id)
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                            .allowsHitTesting(false)
                            .zIndex(10_000)
                    }
                }
                .animation(.easeInOut(duration: 0.12), value: payload?.id)
        }
    }
}

private struct TooltipOverlay: View {
    let payload: TooltipPayload
    let rootSize: CGSize

    @State private var bubbleSize: CGSize = .zero

    var body: some View {
        TooltipBubble(text: payload.text)
            .fixedSize()
            .background(
                GeometryReader { bg in
                    Color.clear
                        .onAppear { bubbleSize = bg.size }
                        .onChange(of: bg.size) { _, newVal in bubbleSize = newVal }
                }
            )
            .offset(x: computedX, y: computedY)
    }

    /// Compute X so the tooltip is horizontally centered under the source,
    /// but clamped to stay inside the root bounds.
    private var computedX: CGFloat {
        guard bubbleSize.width > 0 else { return 0 }
        let margin: CGFloat = 8
        let desired = payload.sourceFrame.midX - bubbleSize.width / 2
        let minX = margin
        let maxX = rootSize.width - bubbleSize.width - margin
        return min(max(desired, minX), maxX)
    }

    /// Compute Y to appear below the source. If it would overflow the bottom,
    /// flip above the source instead.
    private var computedY: CGFloat {
        guard bubbleSize.height > 0 else { return 0 }
        let gap: CGFloat = 6
        let margin: CGFloat = 8
        let below = payload.sourceFrame.maxY + gap
        let above = payload.sourceFrame.minY - bubbleSize.height - gap

        // Prefer below — fall back to above if not enough space
        if below + bubbleSize.height + margin > rootSize.height {
            if above >= margin {
                return above
            }
            // Neither fits fully — clamp to inside the window.
            return rootSize.height - bubbleSize.height - margin
        }
        return below
    }
}

// MARK: - The tooltip bubble

public struct TooltipBubble: View {
    let text: String

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            ForEach(Array(lines.enumerated()), id: \.offset) { (idx, line) in
                if idx == 0 {
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
        .frame(maxWidth: 340, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.5), radius: 8, x: 0, y: 3)
        )
    }
}

// MARK: - Public API

public extension View {
    /// Show a custom fast-appearing tooltip on hover.
    /// The tooltip renders at the root level (attach `.tooltipHost()` there)
    /// so it is never clipped and always appears on top.
    func tooltip(_ text: String, delay: Double = 0.35) -> some View {
        modifier(TooltipModifier(text: text, delay: delay))
    }

    /// Call this **once** on the outermost view of your app so the tooltip
    /// bubble can render above everything without being clipped.
    func tooltipHost() -> some View {
        modifier(TooltipHost())
    }
}
