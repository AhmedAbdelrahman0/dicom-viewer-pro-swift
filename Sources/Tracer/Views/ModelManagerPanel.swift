import SwiftUI

/// One pane of glass for every model Tracer knows about.  Lists local
/// downloads, DGX-hosted artifacts, and remembers what each is bound to.
/// Opens as an inspector from the AI Engines menu (⌘⇧W).
public struct ModelManagerPanel: View {
    @ObservedObject public var vm: ModelManagerViewModel
    @ObservedObject private var store: TracerModelStore
    @ObservedObject private var downloader: ModelDownloadManager

    public init(vm: ModelManagerViewModel) {
        self.vm = vm
        self._store = ObservedObject(wrappedValue: vm.store)
        self._downloader = ObservedObject(wrappedValue: vm.downloader)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            registerForm
            Divider()
            modelList
            Divider()
            statusLine
        }
        .padding(14)
        .frame(minWidth: 520)
        .sheet(isPresented: $vm.showingBindSheet) { bindingSheet }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Image(systemName: "externaldrive.fill.badge.icloud")
                .foregroundColor(.accentColor)
            Text("Model Manager")
                .font(.headline)
            Spacer()
            Text("\(store.models.count) registered")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private var registerForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Register a new model")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            TextField("Display name — e.g. LesionTracer fold 0",
                      text: $vm.newDisplayName)
                .textFieldStyle(.roundedBorder)

            Picker("Kind", selection: $vm.newKind) {
                ForEach([
                    TracerModel.Kind.coreML,
                    .gguf,
                    .treeModelJSON,
                    .nnunetDataset,
                    .monaiBundle,
                    .pythonScript,
                    .remoteArtifact
                ], id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
            .pickerStyle(.menu)

            if vm.newKind == .remoteArtifact {
                TextField("Remote path on DGX — e.g. ~/nnUNet_results/Dataset221",
                          text: $vm.newRemotePath)
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField("Source URL (HuggingFace / Zenodo / any https)",
                          text: $vm.newSourceURL)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
            }

            TextField("License — e.g. Apache-2.0 / CC-BY-4.0 / research-only",
                      text: $vm.newLicense)
                .textFieldStyle(.roundedBorder)

            TextField("Notes (optional)", text: $vm.newNotes)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button {
                    vm.registerFromForm()
                } label: {
                    Label("Register", systemImage: "plus.circle")
                }
                #if canImport(AppKit)
                Button {
                    vm.importFromDisk()
                } label: {
                    Label("Import from disk…", systemImage: "square.and.arrow.down")
                }
                #endif
                Spacer()
            }
        }
    }

    private var modelList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Registered models")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            if store.models.isEmpty {
                Text("No models yet. Register one above, import from disk, or paste a HuggingFace / Zenodo URL.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(store.models) { model in
                            row(model)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
    }

    private func row(_ model: TracerModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(model.displayName, systemImage: iconName(for: model.kind))
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text(model.kind.displayName)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text(ModelManagerViewModel.formatSize(model.sizeBytes))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                statusBadge(for: model)
            }
            if !model.license.isEmpty {
                Label(model.license, systemImage: "doc.text")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            if !model.boundCatalogEntryIDs.isEmpty {
                FlowRow(items: model.boundCatalogEntryIDs) { entryID in
                    HStack(spacing: 2) {
                        Text(entryID)
                            .font(.system(size: 9, design: .monospaced))
                        Button {
                            vm.unbind(modelID: model.id, from: entryID)
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 8))
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.15)))
                }
            }
            HStack {
                if model.kind != .remoteArtifact,
                   model.sourceURL != nil,
                   downloader.status(for: model.id) != .completed(sizeBytes: model.sizeBytes) {
                    Button {
                        Task { await vm.download(model) }
                    } label: {
                        Label("Download", systemImage: "icloud.and.arrow.down")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                Button {
                    vm.startBinding(for: model.id)
                } label: {
                    Label("Bind to catalog", systemImage: "link")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                Spacer()
                Menu {
                    Button(role: .destructive) {
                        vm.remove(model, deleteFiles: false)
                    } label: {
                        Label("Remove from registry", systemImage: "minus.circle")
                    }
                    Button(role: .destructive) {
                        vm.remove(model, deleteFiles: true)
                    } label: {
                        Label("Remove + delete files", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.vertical, 6)
    }

    private func statusBadge(for model: TracerModel) -> some View {
        let status = downloader.status(for: model.id)
        return Group {
            switch status {
            case .idle:
                if model.existsLocally {
                    Label("Ready", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else if model.kind == .remoteArtifact {
                    Label("Remote", systemImage: "network")
                        .foregroundColor(.accentColor)
                } else {
                    Label("Not downloaded", systemImage: "questionmark.circle")
                        .foregroundColor(.secondary)
                }
            case .downloading(let received, let total):
                let fraction = total > 0 ? Double(received) / Double(total) : 0
                HStack(spacing: 4) {
                    ProgressView(value: fraction).frame(width: 60)
                    if total > 0 {
                        Text("\(Int(fraction * 100))%")
                            .font(.system(size: 10, design: .monospaced))
                    }
                }
            case .verifying:
                Label("Verifying", systemImage: "checkmark.shield").foregroundColor(.orange)
            case .completed:
                Label("Ready", systemImage: "checkmark.circle.fill").foregroundColor(.green)
            case .failed(let m):
                Label(m, systemImage: "xmark.octagon.fill").foregroundColor(.red)
                    .lineLimit(1)
            case .cancelled:
                Label("Cancelled", systemImage: "xmark.circle")
                    .foregroundColor(.secondary)
            }
        }
        .font(.system(size: 10))
    }

    private var statusLine: some View {
        Text(vm.statusMessage)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Binding sheet

    private var bindingSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bind model to catalog entry")
                .font(.headline)
            TextField("Filter", text: $vm.bindingCatalogQuery)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(vm.bindableEntries, id: \.id) { entry in
                        Button {
                            vm.finishBinding(catalogEntryID: entry.id)
                        } label: {
                            HStack {
                                Text(entry.displayName)
                                    .font(.system(size: 12))
                                Spacer()
                                Text(entry.id)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 3)
                    }
                }
            }
            .frame(minHeight: 280)
            HStack {
                Spacer()
                Button("Cancel") { vm.showingBindSheet = false }
            }
        }
        .padding(20)
        .frame(width: 520, height: 440)
    }

    private func iconName(for kind: TracerModel.Kind) -> String {
        switch kind {
        case .coreML:         return "cpu"
        case .nnunetDataset:  return "square.stack.3d.up.fill"
        case .gguf:           return "brain.head.profile"
        case .treeModelJSON:  return "leaf"
        case .monaiBundle:    return "shippingbox"
        case .pythonScript:   return "terminal"
        case .remoteArtifact: return "network"
        }
    }
}

/// Tiny flow layout for chip rows — SwiftUI's built-in HStack won't wrap
/// when the chips overflow, so we hand-roll a basic wrapper.
private struct FlowRow<T: Hashable, Content: View>: View {
    let items: [T]
    let content: (T) -> Content
    private let columns = [
        GridItem(.adaptive(minimum: 96), spacing: 4, alignment: .leading)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { item in
                content(item)
            }
        }
    }
}
