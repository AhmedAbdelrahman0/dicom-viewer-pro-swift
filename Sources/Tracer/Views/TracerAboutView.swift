import SwiftUI

#if os(macOS)

/// Standard macOS "About Tracer" window, replacing the default
/// `NSApplication.orderFrontStandardAboutPanel`. Shows:
///
///   • the app icon + brand hero,
///   • version + build number (pulled from Info.plist),
///   • a compact changelog for this release,
///   • links to the repo + the licenses of the AI models Tracer wraps.
///
/// Opened via the "About Tracer" menu item (wired in `DicomViewerApp`).
public struct TracerAboutView: View {
    @Environment(\.openURL) private var openURL

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            hero
            Divider()
            changelog
            Divider()
            acknowledgements
            Spacer(minLength: 0)
            footer
        }
        .padding(22)
        .frame(width: 520, height: 580)
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .top, spacing: 14) {
            brandIcon
                .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 4) {
                Text("Tracer")
                    .font(.system(size: 22, weight: .semibold))
                Text("AI-assisted imaging workstation")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    Text("Version \(Self.appVersion)")
                        .font(.system(size: 11, design: .monospaced))
                    Text("(build \(Self.appBuild))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 2)
            }
        }
    }

    /// Programmatic brand mark — matches the shipped `.icns` motif (three
    /// concentric rings + a bright centre tracer dot + a diagonal sweep).
    /// Kept in code so it always renders crisply at any retina scale and
    /// doesn't depend on the bundled icon file being present in debug
    /// builds.
    private var brandIcon: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.08, green: 0.12, blue: 0.22),
                                     Color(red: 0.04, green: 0.06, blue: 0.12)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .strokeBorder(Color.accentColor.opacity(0.85 - Double(i) * 0.22),
                                       lineWidth: 1.5)
                        .frame(width: size * (0.28 + CGFloat(i) * 0.16),
                               height: size * (0.28 + CGFloat(i) * 0.16))
                }
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: size * 0.14, height: size * 0.14)
                    .shadow(color: .accentColor.opacity(0.7), radius: size * 0.08)
                Path { p in
                    p.move(to: CGPoint(x: size * 0.15, y: size * 0.85))
                    p.addLine(to: CGPoint(x: size * 0.85, y: size * 0.15))
                }
                .stroke(Color.accentColor.opacity(0.45),
                        style: StrokeStyle(lineWidth: size * 0.015, dash: [size * 0.04, size * 0.04]))
            }
        }
    }

    // MARK: - Changelog

    private var changelog: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("What's new in this build")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            ForEach(Self.changelogItems, id: \.self) { line in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").foregroundColor(.accentColor)
                    Text(line).font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Acknowledgements

    private var acknowledgements: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("AI backends Tracer wraps")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            acknowledgementRow("nnU-Net v2", "Isensee et al. — Apache-2.0")
            acknowledgementRow("MONAI Label", "Project MONAI — Apache-2.0")
            acknowledgementRow("MONAI Deploy Informatics Gateway", "Project MONAI — Apache-2.0")
            acknowledgementRow("AutoPET II / III (LesionTracer)", "MIC-DKFZ — code Apache-2.0, weights CC-BY-4.0")
            acknowledgementRow("MedSAM2", "Bo Wang Lab — Apache-2.0")
            acknowledgementRow("TotalSegmentator", "Wasserthal et al. — Apache-2.0 (core)")
            acknowledgementRow("Level-set ideas", "Yushkevich 2006 (ITK-SNAP paper) — re-implemented")
        }
    }

    private func acknowledgementRow(_ name: String, _ note: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).font(.system(size: 11, weight: .medium))
            Spacer()
            Text(note).font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button {
                if let url = URL(string: "https://github.com/AhmedAbdelrahman0/tracer") {
                    openURL(url)
                }
            } label: {
                Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            Spacer()
            Text("© 2026 · Research / educational use")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Static metadata

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }

    private static var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    /// Hand-curated changelog for the current release. Kept short — the
    /// full history lives in git. Re-author with each version bump.
    private static let changelogItems: [String] = [
        "Renamed: DicomViewerPro → Tracer, module + bundle identifiers refreshed.",
        "Toolbar consolidation: three AI buttons → one “AI Engines” menu (⌘⇧M / ⌘⇧N / ⌘⇧P).",
        "Focus Mode (⌘E) hides the side panels so the MPR viewport fills the window.",
        "Cursor badge on every slice — live voxel coordinates, raw intensity, SUV, active label class.",
        "Right-click context menu with Cursor · Tools · View sections.",
        "Recently-opened volumes strip at the top of the Study Browser.",
        "ControlsPanel reorganised from 7 flat tabs to 5 grouped tabs with nested sub-tabs.",
        "Engine panels (MONAI / nnU-Net / PET) open as side inspector drawers (sheet on iPad compact).",
        "Drag-and-drop folders or NIfTI files onto the Study Browser to load them.",
        "⌘1 / ⌘2 / ⌘3 W/L preset shortcuts (rebind in Settings → Shortcuts).",
        "PET Engine: AutoPET II/III/IV catalog, MedSAM2 box-prompt, TMTV/TLG, physiological uptake filter.",
        "Multi-channel nnU-Net inference for CT+PET models.",
        "Settings window (⌘,) — rebind shortcuts + store default MONAI URL / nnU-Net paths."
    ]
}

#endif
