import SwiftUI
import UniformTypeIdentifiers

struct LabelingPanel: View {
    @EnvironmentObject var vm: ViewerViewModel
    @State private var showingPresetPicker = false
    @State private var showingNewClassSheet = false
    @State private var newClassName: String = ""
    @State private var newClassColor: Color = .red
    @State private var newClassCategory: LabelCategory = .lesion
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var exportFormat: LabelIO.Format = .niftiLabelmap

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {

                // ── Label map management ──
                Group {
                    Text("Label Maps")
                        .font(.headline)

                    if vm.labeling.labelMaps.isEmpty {
                        Text("No label maps yet")
                            .foregroundColor(.secondary)
                        Button {
                            if let v = vm.currentVolume {
                                vm.labeling.createLabelMap(for: v)
                            }
                        } label: {
                            Label("Create Empty Label Map", systemImage: "plus.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.currentVolume == nil)
                    } else {
                        Picker("Active", selection: Binding(
                            get: { vm.labeling.activeLabelMap?.id },
                            set: { newID in
                                vm.labeling.activeLabelMap =
                                    vm.labeling.labelMaps.first { $0.id == newID }
                            }
                        )) {
                            ForEach(vm.labeling.labelMaps) { m in
                                Text(m.name).tag(m.id as UUID?)
                            }
                        }

                        HStack {
                            if let map = vm.labeling.activeLabelMap {
                                Toggle("Visible", isOn: Binding(
                                    get: { map.visible },
                                    set: { map.visible = $0; map.objectWillChange.send() }
                                ))
                                Spacer()
                                Text("\(Int(map.opacity * 100))%")
                                    .font(.system(size: 10, design: .monospaced))
                            }
                        }
                        if let map = vm.labeling.activeLabelMap {
                            Slider(value: Binding(
                                get: { map.opacity },
                                set: { map.opacity = $0; map.objectWillChange.send() }
                            ), in: 0.1...1.0)
                        }

                        Button {
                            if let v = vm.currentVolume {
                                vm.labeling.createLabelMap(for: v)
                            }
                        } label: {
                            Label("New Label Map", systemImage: "plus")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                Divider()

                // ── Presets ──
                Group {
                    HStack {
                        Text("Presets")
                            .font(.headline)
                        Spacer()
                        Button {
                            showingPresetPicker = true
                        } label: {
                            Label("Load Preset…", systemImage: "list.bullet.rectangle")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(vm.labeling.activeLabelMap == nil)
                    }
                }

                Divider()

                // ── Classes ──
                if let map = vm.labeling.activeLabelMap {
                    Group {
                        Text("Classes (\(map.classes.count))")
                            .font(.headline)

                        ForEach(LabelCategory.allCases) { cat in
                            let classesInCat = map.classes.filter { $0.category == cat }
                            if !classesInCat.isEmpty {
                                DisclosureGroup {
                                    VStack(alignment: .leading, spacing: 2) {
                                        ForEach(classesInCat) { cls in
                                            ClassRow(
                                                cls: cls,
                                                isActive: vm.labeling.activeClassID == cls.labelID,
                                                onSelect: { vm.labeling.selectClass(cls.labelID) },
                                                onToggleVisible: {
                                                    if let idx = map.classes.firstIndex(where: { $0.id == cls.id }) {
                                                        map.classes[idx].visible.toggle()
                                                        map.objectWillChange.send()
                                                    }
                                                }
                                            )
                                        }
                                    }
                                } label: {
                                    Label("\(cat.rawValue)  (\(classesInCat.count))",
                                          systemImage: cat.icon)
                                        .font(.system(size: 12, weight: .semibold))
                                }
                            }
                        }

                        Button {
                            showingNewClassSheet = true
                        } label: {
                            Label("New Class…", systemImage: "plus")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                Divider()

                // ── Tools ──
                Group {
                    Text("Tools").font(.headline)

                    // Segmented picker with per-tool hover tooltips
                    HStack(spacing: 2) {
                        ForEach(LabelingTool.allCases) { t in
                            HoverIconButton(
                                systemImage: t.systemImage,
                                tooltip: t.helpText,
                                isActive: vm.labeling.labelingTool == t
                            ) {
                                vm.labeling.labelingTool = t
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(4)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(6)

                    switch vm.labeling.labelingTool {
                    case .brush, .eraser:
                        HStack {
                            Text("Brush size")
                            Slider(value: Binding(
                                get: { Double(vm.labeling.brushRadius) },
                                set: { vm.labeling.brushRadius = Int($0) }
                            ), in: 1...20, step: 1)
                            Text("\(vm.labeling.brushRadius)")
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 30)
                        }
                        Toggle("3D Brush (sphere)", isOn: $vm.labeling.brush3D)

                    case .threshold:
                        VStack(alignment: .leading) {
                            HStack {
                                Text("SUV / Intensity ≥")
                                Spacer()
                                Text(String(format: "%.2f", vm.labeling.thresholdValue))
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            Slider(value: $vm.labeling.thresholdValue, in: 0...50)

                            HStack {
                                Button("Apply (whole volume)") {
                                    if let v = vm.currentVolume {
                                        vm.labeling.thresholdAll(volume: v,
                                                                  above: vm.labeling.thresholdValue)
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }

                            Divider()
                            Text("% of SUV max (40% is EANM std)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            HStack {
                                Slider(value: $vm.labeling.percentOfMax, in: 0.1...0.9)
                                Text(String(format: "%.0f%%", vm.labeling.percentOfMax * 100))
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 40)
                            }
                        }

                    case .regionGrow:
                        VStack(alignment: .leading) {
                            HStack {
                                Text("Tolerance")
                                Slider(value: $vm.labeling.regionGrowTolerance, in: 0...500)
                                Text(String(format: "%.0f", vm.labeling.regionGrowTolerance))
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 40)
                            }
                            Text("Click on the seed voxel in any view to grow the region.")
                                .font(.caption).foregroundColor(.secondary)
                        }

                    case .landmark:
                        VStack(alignment: .leading) {
                            Picker("Next point", selection: $vm.labeling.landmarkCaptureTarget) {
                                ForEach(LandmarkCaptureTarget.allCases) { target in
                                    Text(target.displayName).tag(target)
                                }
                            }
                            .pickerStyle(.segmented)
                            Text("Landmark pairs: \(vm.labeling.landmarks.count)")
                            if vm.labeling.treMM > 0 {
                                Text("TRE: \(String(format: "%.2f mm", vm.labeling.treMM))")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            if vm.labeling.pendingFixedLandmark != nil || vm.labeling.pendingMovingLandmark != nil {
                                Button {
                                    vm.labeling.cancelPendingLandmark()
                                } label: {
                                    Label("Cancel Pending Point", systemImage: "mappin.slash")
                                        .font(.system(size: 11))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            Button(role: .destructive) {
                                vm.labeling.clearLandmarks()
                            } label: {
                                Label("Clear Landmarks", systemImage: "xmark.circle")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                    default:
                        EmptyView()
                    }
                }

                Divider()

                // ── Morphology shortcuts ──
                Group {
                    Text("Morphology").font(.headline)
                    HStack {
                        Button {
                            vm.labeling.dilateActive(iterations: 1)
                        } label: {
                            Label("Dilate", systemImage: "arrow.up.left.and.arrow.down.right")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button {
                            vm.labeling.erodeActive(iterations: 1)
                        } label: {
                            Label("Erode", systemImage: "arrow.down.right.and.arrow.up.left")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                Divider()

                // ── Region statistics ──
                if let map = vm.labeling.activeLabelMap,
                   let v = vm.currentVolume,
                   let cls = map.classInfo(id: vm.labeling.activeClassID) {
                    Group {
                        Text("Statistics: \(cls.name)")
                            .font(.headline)
                        let stats = RegionStats.compute(v, map, classID: cls.labelID)
                        if stats.count == 0 {
                            Text("No voxels in this class")
                                .font(.caption).foregroundColor(.secondary)
                        } else {
                            StatRow("Voxels", "\(stats.count)")
                            StatRow("Volume", String(format: "%.1f cm³", stats.volumeMM3 / 1000))
                            StatRow("Mean", String(format: "%.1f", stats.mean))
                            StatRow("Max",  String(format: "%.1f", stats.max))
                            StatRow("Min",  String(format: "%.1f", stats.min))
                            StatRow("Std",  String(format: "%.1f", stats.std))
                            if let suvMax = stats.suvMax {
                                StatRow("SUV max", String(format: "%.2f", suvMax))
                            }
                            if let suvMean = stats.suvMean {
                                StatRow("SUV mean", String(format: "%.2f", suvMean))
                            }
                            if let tlg = stats.tlg {
                                StatRow("TLG", String(format: "%.1f g·mL⁻¹·mL", tlg))
                            }
                        }
                    }
                }

                Divider()

                // ── Import/Export ──
                Group {
                    Text("Save / Load").font(.headline)
                    HStack {
                        Button {
                            showingImporter = true
                        } label: {
                            Label("Import", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button {
                            showingExporter = true
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(vm.labeling.activeLabelMap == nil)
                    }

                    Picker("Format", selection: $exportFormat) {
                        ForEach(LabelIO.Format.allCases) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }
                    .font(.system(size: 11))
                }

                Spacer()
            }
            .padding()
        }
        .sheet(isPresented: $showingPresetPicker) {
            PresetPickerSheet(vm: vm, isPresented: $showingPresetPicker)
        }
        .sheet(isPresented: $showingNewClassSheet) {
            NewClassSheet(isPresented: $showingNewClassSheet,
                          name: $newClassName,
                          color: $newClassColor,
                          category: $newClassCategory,
                          onAdd: {
                              vm.labeling.addClass(name: newClassName,
                                                    color: newClassColor,
                                                    category: newClassCategory)
                              newClassName = ""
                          })
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: LabelDocumentRef(vm: vm, format: exportFormat),
            contentType: .data,
            defaultFilename: "labels"
        ) { result in
            if case .success(let url) = result,
               let v = vm.currentVolume {
                try? vm.labeling.saveActiveLabel(to: url,
                                                   format: exportFormat,
                                                   parentVolume: v)
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.data, .item],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first,
                  let v = vm.currentVolume else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            try? vm.labeling.loadLabel(from: url, parentVolume: v)
        }
    }
}

// MARK: - Class row

private struct ClassRow: View {
    let cls: LabelClass
    let isActive: Bool
    let onSelect: () -> Void
    let onToggleVisible: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                onToggleVisible()
            } label: {
                Image(systemName: cls.visible ? "eye" : "eye.slash")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            RoundedRectangle(cornerRadius: 3)
                .fill(cls.color)
                .frame(width: 14, height: 14)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
                )

            Button(action: onSelect) {
                HStack {
                    Text(cls.name)
                        .font(.system(size: 11))
                        .foregroundColor(.primary)
                    Spacer()
                    Text("\(cls.labelID)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
        .cornerRadius(4)
    }
}

// MARK: - Preset picker

private struct PresetPickerSheet: View {
    @ObservedObject var vm: ViewerViewModel
    @Binding var isPresented: Bool
    @State private var search: String = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered) { preset in
                    Button {
                        vm.labeling.applyPreset(preset)
                        isPresented = false
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(preset.name).font(.headline)
                            Text(preset.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(preset.classes.count) classes")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .searchable(text: $search, prompt: "Search presets…")
            .navigationTitle("Label Presets")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
        .frame(minWidth: 500, minHeight: 500)
    }

    private var filtered: [LabelPresetSet] {
        if search.isEmpty { return LabelPresets.all }
        return LabelPresets.all.filter {
            $0.name.localizedCaseInsensitiveContains(search) ||
            $0.description.localizedCaseInsensitiveContains(search)
        }
    }
}

// MARK: - New class sheet

private struct NewClassSheet: View {
    @Binding var isPresented: Bool
    @Binding var name: String
    @Binding var color: Color
    @Binding var category: LabelCategory
    let onAdd: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Picker("Category", selection: $category) {
                    ForEach(LabelCategory.allCases) { cat in
                        Label(cat.rawValue, systemImage: cat.icon).tag(cat)
                    }
                }
                ColorPicker("Color", selection: $color)
            }
            .navigationTitle("New Class")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { onAdd(); isPresented = false }
                        .disabled(name.isEmpty)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 250)
    }
}

// MARK: - Stat row

private struct StatRow: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }
    var body: some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.system(size: 11, design: .monospaced))
        }
    }
}

// MARK: - Document wrapper for file export

private struct LabelDocumentRef: FileDocument {
    @MainActor static var readableContentTypes: [UTType] { [.data] }
    static var writableContentTypes: [UTType] { [.data] }

    var vm: ViewerViewModel
    var format: LabelIO.Format

    @MainActor
    init(vm: ViewerViewModel, format: LabelIO.Format) {
        self.vm = vm
        self.format = format
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // The actual file is written in the .fileExporter result handler.
        return FileWrapper(regularFileWithContents: Data())
    }
}
