import SwiftUI

#if os(macOS)

public struct ContainerRuntimeSetupInlineView: View {
    @ObservedObject var store: ContainerRuntimeSetupStore

    public init(store: ContainerRuntimeSetupStore) {
        self.store = store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(statusTitle, systemImage: statusIcon)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if store.isInstalling {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text(statusDetail)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("Check", systemImage: "arrow.clockwise")
                }
                .disabled(store.isInstalling)

                Button {
                    Task { await store.installAndStart() }
                } label: {
                    Label("Install Local Runtime", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canInstall)
            }
        }
        .task {
            if case .idle = store.status {
                await store.refresh()
            }
        }
    }

    private var canInstall: Bool {
        if store.isInstalling { return false }
        if case .setupRequired(let plan) = store.status {
            return plan.canInstallWithHomebrew
        }
        return false
    }

    private var statusTitle: String {
        switch store.status {
        case .idle, .checking:
            return "Checking local runtime"
        case .ready:
            return "Local runtime ready"
        case .setupRequired:
            return "Local runtime setup required"
        case .installing:
            return "Setting up local runtime"
        case .failed:
            return "Local runtime setup needs attention"
        }
    }

    private var statusDetail: String {
        switch store.status {
        case .idle:
            return "Tracer has not checked the local runtime yet."
        case .checking:
            return "Checking for Docker and Colima."
        case .ready(let message), .installing(let message), .failed(let message):
            return message
        case .setupRequired(let plan):
            if plan.canInstallWithHomebrew {
                return plan.summary
            }
            return plan.summary + " Run `brew install docker colima` after Homebrew is available."
        }
    }

    private var statusIcon: String {
        switch store.status {
        case .idle, .checking:
            return "magnifyingglass"
        case .ready:
            return "checkmark.circle"
        case .setupRequired:
            return "exclamationmark.triangle"
        case .installing:
            return "arrow.triangle.2.circlepath"
        case .failed:
            return "xmark.octagon"
        }
    }
}

public struct ContainerRuntimeSetupSheet: View {
    @ObservedObject var store: ContainerRuntimeSetupStore
    @Binding var isPresented: Bool
    @AppStorage(TracerSettings.Keys.containerRuntimeSetupPromptDismissed) private var promptDismissed: Bool = false

    public init(store: ContainerRuntimeSetupStore,
                isPresented: Binding<Bool>) {
        self.store = store
        _isPresented = isPresented
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "shippingbox.and.arrow.backward")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(TracerTheme.accentBright)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Local Runtime Setup")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Install Docker and Colima once so local AI workers can run in containers.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Divider()

            ContainerRuntimeSetupInlineView(store: store)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                RuntimeToolRow(name: "Homebrew", value: store.plan.homebrewPath)
                RuntimeToolRow(name: "Docker CLI", value: store.plan.dockerPath)
                RuntimeToolRow(name: "Colima", value: store.plan.colimaPath)
            }

            HStack {
                Button("Skip For Now") {
                    promptDismissed = true
                    isPresented = false
                }
                .disabled(store.isInstalling)

                Spacer()

                Button("Close") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                .disabled(store.isInstalling)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(TracerTheme.panelBackground)
        .task {
            await store.refresh()
        }
    }
}

private struct RuntimeToolRow: View {
    let name: String
    let value: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: value == nil ? "circle" : "checkmark.circle.fill")
                .foregroundColor(value == nil ? .secondary : .green)
                .frame(width: 18)
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 88, alignment: .leading)
            Text(value ?? "Missing")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(value == nil ? .secondary : .primary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

#endif
