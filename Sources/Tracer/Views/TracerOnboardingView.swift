import SwiftUI

#if os(macOS)

/// First-launch welcome walkthrough. Three cards; user can dismiss at any
/// point. Re-openable from Help → Show Welcome Walkthrough.
///
/// Designed to tell a brand-new user the *three things they must know*
/// before they'll succeed with the app:
///   1. How to open a study.
///   2. How to drive the AI engines.
///   3. How to reach Settings + shortcuts.
///
/// Kept intentionally short — no slide 4 or 5. Longer docs live in the
/// README and the About window's changelog.
public struct TracerOnboardingView: View {
    @Binding public var isPresented: Bool
    public let onDismiss: () -> Void

    @State private var cardIndex: Int = 0

    private let cards: [Card] = [
        Card(
            icon: "square.and.arrow.down",
            title: "Open a study",
            body: "Drop a DICOM folder or a .nii / .nii.gz file onto the Study Browser on the left. Or use ⌘O (DICOM directory) / ⌘N (NIfTI file). Recently-opened volumes appear as chips at the top of the browser.",
            accentColor: .blue
        ),
        Card(
            icon: "cpu",
            title: "Call an AI engine",
            body: "Top toolbar → AI Engines menu. Choose MONAI Label, nnU-Net, or the PET Engine. Each opens as a side drawer (iPad portrait gets a sheet). Or just ask the Assistant chat — it routes natural-language requests to the right model.",
            accentColor: .orange
        ),
        Card(
            icon: "keyboard",
            title: "Shortcuts + Settings",
            body: "⌘1 / ⌘2 / ⌘3 apply W/L presets (Lung / Bone / Brain by default — rebindable in Settings). ⌘R for auto W/L, ⌘E for Focus Mode, ⌘⇧A to jump to Assistant chat. ⌘, opens Settings.",
            accentColor: .green
        )
    ]

    public init(isPresented: Binding<Bool>,
                onDismiss: @escaping () -> Void) {
        self._isPresented = isPresented
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            card(cards[cardIndex])
                .frame(maxWidth: .infinity)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                .animation(.easeInOut(duration: 0.2), value: cardIndex)
            Divider()
            footer
        }
        .frame(width: 500, height: 420)
    }

    private var header: some View {
        HStack {
            Text("Welcome to Tracer")
                .font(.title2.weight(.semibold))
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private func card(_ card: Card) -> some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(card.accentColor.opacity(0.15))
                Image(systemName: card.icon)
                    .font(.system(size: 42, weight: .light))
                    .foregroundColor(card.accentColor)
            }
            .frame(width: 96, height: 96)

            Text(card.title)
                .font(.title3.weight(.semibold))

            Text(card.body)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)

            Spacer(minLength: 0)
        }
        .padding(.top, 18)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            // Dot-dot-dot page indicator.
            HStack(spacing: 5) {
                ForEach(0..<cards.count, id: \.self) { i in
                    Circle()
                        .fill(i == cardIndex ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                        .onTapGesture { cardIndex = i }
                }
            }
            Spacer()
            if cardIndex > 0 {
                Button("Back") { cardIndex -= 1 }
                    .keyboardShortcut(.leftArrow, modifiers: [])
            }
            if cardIndex < cards.count - 1 {
                Button("Next") { cardIndex += 1 }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Get started") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private func dismiss() {
        isPresented = false
        onDismiss()
    }

    private struct Card {
        let icon: String
        let title: String
        let body: String
        let accentColor: Color
    }
}

#endif
