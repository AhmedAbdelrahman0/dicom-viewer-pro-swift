import SwiftUI

enum TracerTheme {
    static let accent = Color(red: 0.03, green: 0.74, blue: 0.78)
    static let accentBright = Color(red: 0.16, green: 0.91, blue: 0.94)
    static let pet = Color(red: 1.0, green: 0.58, blue: 0.23)
    static let label = Color(red: 0.36, green: 0.84, blue: 0.54)
    static let warning = Color(red: 1.0, green: 0.70, blue: 0.28)

    static let windowBackground = Color(red: 0.025, green: 0.029, blue: 0.033)
    static let viewportBackground = Color(red: 0.006, green: 0.008, blue: 0.010)
    static let sidebarBackground = Color(red: 0.055, green: 0.061, blue: 0.066)
    static let panelBackground = Color(red: 0.040, green: 0.045, blue: 0.050)
    static let panelRaised = Color(red: 0.085, green: 0.092, blue: 0.098)
    static let panelPressed = Color(red: 0.110, green: 0.120, blue: 0.128)
    static let hairline = Color.white.opacity(0.105)
    static let strongHairline = Color.white.opacity(0.18)
    static let mutedText = Color.white.opacity(0.54)

    static var toolbarBackground: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.115, green: 0.124, blue: 0.132),
                Color(red: 0.070, green: 0.076, blue: 0.082)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static var headerBackground: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.068, green: 0.076, blue: 0.084),
                Color(red: 0.042, green: 0.047, blue: 0.052)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static var activeGradient: LinearGradient {
        LinearGradient(
            colors: [accentBright, accent],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var worklistGradient: LinearGradient {
        LinearGradient(
            colors: [
                sidebarBackground,
                Color(red: 0.034, green: 0.038, blue: 0.043)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

struct TracerChromeBorder: ViewModifier {
    var cornerRadius: CGFloat = 6
    var isActive: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(TracerTheme.panelRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(isActive ? TracerTheme.accent.opacity(0.65) : TracerTheme.hairline,
                            lineWidth: isActive ? 1.2 : 1)
            )
    }
}

extension View {
    func tracerChrome(cornerRadius: CGFloat = 6, active: Bool = false) -> some View {
        modifier(TracerChromeBorder(cornerRadius: cornerRadius, isActive: active))
    }
}
