import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

struct LabelingPanel: View {
    @EnvironmentObject var vm: ViewerViewModel
    @State private var showingPresetPicker = false
    @State private var showingNewClassSheet = false
    @State private var newClassName: String = ""
    @State private var newClassColor: Color = .red
    @State private var newClassCategory: LabelCategory = .lesion
    @State private var showingFormatGuide = false
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var pendingConversion: PendingLabelConversion?
    @State private var exportFormat: LabelIO.Format = .niftiLabelmap
    @State private var meshExportFormat: MarchingCubesMeshExporter.Format = .stl
    @State private var meshSmoothingIterations: Int = 1
    @State private var marginIterations: Int = 1
    @State private var smoothingMode: LabelSmoothingMode = .median
    @State private var smoothingIterations: Int = 1
    @State private var hollowThickness: Int = 1
    @State private var fillBetweenAxis: Int = 2
    @State private var islandMinimumVoxels: Int = 10
    @State private var logicalSourceClassID: UInt16 = 0
    @State private var selectedHUPresetID: String = HUThresholdPreset.presets[1].id
    @State private var ctLowerHU: Double = HUThresholdPreset.presets[1].lower
    @State private var ctUpperHU: Double = HUThresholdPreset.presets[1].upper

    private var activeClassName: String {
        vm.labeling.activeLabelMap?
            .classInfo(id: vm.labeling.activeClassID)?
            .name ?? "Label \(vm.labeling.activeClassID)"
    }

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

                        HStack {
                            Button {
                                vm.undoLastEdit()
                            } label: {
                                Label("Undo", systemImage: "arrow.uturn.backward")
                                    .frame(maxWidth: .infinity)
                            }
                            .disabled(!vm.canUndo)

                            Button {
                                vm.redoLastEdit()
                            } label: {
                                Label("Redo", systemImage: "arrow.uturn.forward")
                                    .frame(maxWidth: .infinity)
                            }
                            .disabled(!vm.canRedo)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        HStack {
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

                            Spacer()
                            if vm.labeling.hasUnsavedChanges {
                                Text("Unsaved")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.orange)
                            }
                        }
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
                                vm.setActiveLabelingTool(t)
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

                    case .freehand:
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Drag a closed contour on a slice, then release to fill it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Active class: \(activeClassName)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }

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
                                    vm.startThresholdActiveLabel(atOrAbove: vm.labeling.thresholdValue)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(vm.isVolumeOperationRunning)
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

                            Stepper("Seed box: \(vm.labeling.percentOfMaxSearchRadius) voxels",
                                    value: $vm.labeling.percentOfMaxSearchRadius,
                                    in: 5...160)
                                .font(.system(size: 11))
                                .help("Local %SUVmax seed search radius for threshold clicks.")
                        }

                    case .suvGradient:
                        VStack(alignment: .leading) {
                            HStack {
                                Text("SUV / Intensity ≥")
                                Spacer()
                                Text(String(format: "%.2f", vm.labeling.thresholdValue))
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            Slider(value: $vm.labeling.thresholdValue, in: 0...50)

                            HStack {
                                Text("Edge stop")
                                Spacer()
                                Text(String(format: "%.2f", vm.labeling.gradientCutoffFraction))
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            Slider(value: $vm.labeling.gradientCutoffFraction, in: 0.05...0.95)

                            Stepper("Radius: \(vm.labeling.gradientSearchRadius) voxels",
                                    value: $vm.labeling.gradientSearchRadius,
                                    in: 5...120)
                                .font(.system(size: 11))
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

                    case .activeContour:
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Speed", selection: $vm.labeling.activeContourMode) {
                                ForEach(ActiveContourSpeedMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)

                            Stepper("Seed radius: \(vm.labeling.activeContourSeedRadius) voxels",
                                    value: $vm.labeling.activeContourSeedRadius,
                                    in: 1...40)
                                .font(.system(size: 11))
                            Stepper("Iterations: \(vm.labeling.activeContourIterations)",
                                    value: $vm.labeling.activeContourIterations,
                                    in: 10...800,
                                    step: 10)
                                .font(.system(size: 11))

                            if vm.labeling.activeContourMode == .regionCompetition {
                                SmallNumberRow("Midpoint", value: $vm.labeling.activeContourMidpoint)
                                SmallNumberRow("Half width", value: $vm.labeling.activeContourHalfWidth)
                            } else {
                                SmallNumberRow("Kappa", value: $vm.labeling.activeContourKappa)
                            }

                            HStack {
                                Text("Prop")
                                Slider(value: $vm.labeling.activeContourPropagation, in: 0...3)
                                Text(String(format: "%.1f", vm.labeling.activeContourPropagation))
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 34)
                            }
                            HStack {
                                Text("Smooth")
                                Slider(value: $vm.labeling.activeContourCurvature, in: 0...1)
                                Text(String(format: "%.2f", vm.labeling.activeContourCurvature))
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 34)
                            }
                            HStack {
                                Text("Edge")
                                Slider(value: $vm.labeling.activeContourAdvection, in: 0...2)
                                Text(String(format: "%.1f", vm.labeling.activeContourAdvection))
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 34)
                            }
                            Text("Click a seed voxel in any slice to evolve the contour.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                    case .lesionSphere:
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Sphere radius")
                                Spacer()
                                Text(String(format: "%.1f mm", vm.labeling.lesionSphereRadiusMM))
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            Slider(value: $vm.labeling.lesionSphereRadiusMM,
                                   in: 2...60,
                                   step: 0.5)

                            HStack(spacing: 6) {
                                Button("5 mm") {
                                    vm.labeling.lesionSphereRadiusMM = 5
                                }
                                Button("10 mm") {
                                    vm.labeling.lesionSphereRadiusMM = 10
                                }
                                Button("20 mm") {
                                    vm.labeling.lesionSphereRadiusMM = 20
                                }
                                Button {
                                    vm.labeling.clearQuickLesions()
                                } label: {
                                    Label("Clear", systemImage: "trash")
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
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

                volumeMeasurementTools

                Divider()

                // ── Morphology shortcuts ──
                Group {
                    Text("Morphology").font(.headline)
                    Stepper("Margin: \(marginIterations) voxel\(marginIterations == 1 ? "" : "s")",
                            value: $marginIterations,
                            in: 1...20)
                        .font(.system(size: 11))
                    HStack {
                        Button {
                            let before = vm.labeling.undoDepth
                            vm.labeling.dilateActive(iterations: marginIterations)
                            vm.recordLabelEditIfChanged(named: "Grow label", beforeUndoDepth: before)
                        } label: {
                            Label("Grow", systemImage: "arrow.up.left.and.arrow.down.right")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button {
                            let before = vm.labeling.undoDepth
                            vm.labeling.erodeActive(iterations: marginIterations)
                            vm.recordLabelEditIfChanged(named: "Shrink label", beforeUndoDepth: before)
                        } label: {
                            Label("Shrink", systemImage: "arrow.down.right.and.arrow.up.left")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Divider()

                    Text("Smoothing").font(.subheadline)
                    Picker("Method", selection: $smoothingMode) {
                        ForEach(LabelSmoothingMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    Stepper("Passes: \(smoothingIterations)",
                            value: $smoothingIterations,
                            in: 1...6)
                        .font(.system(size: 11))
                    HStack {
                        Button {
                            let before = vm.labeling.undoDepth
                            let changed = vm.labeling.smoothActive(mode: smoothingMode,
                                                                   iterations: smoothingIterations)
                            vm.recordLabelEditIfChanged(named: "\(smoothingMode.displayName) smooth",
                                                        beforeUndoDepth: before)
                            vm.statusMessage = "\(smoothingMode.displayName) smoothing changed \(changed) voxels"
                        } label: {
                            Label("Smooth", systemImage: "wand.and.stars")
                                .frame(maxWidth: .infinity)
                        }
                        Button {
                            let before = vm.labeling.undoDepth
                            let filled = vm.labeling.fillHolesActive()
                            vm.recordLabelEditIfChanged(named: "Fill holes", beforeUndoDepth: before)
                            vm.statusMessage = "Filled \(filled) enclosed voxels"
                        } label: {
                            Label("Fill Holes", systemImage: "circle.dotted")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Divider()

                    Text("Shape").font(.subheadline)
                    Stepper("Shell: \(hollowThickness) voxel\(hollowThickness == 1 ? "" : "s")",
                            value: $hollowThickness,
                            in: 1...12)
                        .font(.system(size: 11))
                    HStack {
                        Button {
                            let before = vm.labeling.undoDepth
                            let removed = vm.labeling.hollowActive(thickness: hollowThickness)
                            vm.recordLabelEditIfChanged(named: "Hollow label", beforeUndoDepth: before)
                            vm.statusMessage = "Hollowed label by removing \(removed) interior voxels"
                        } label: {
                            Label("Hollow", systemImage: "circle.hexagongrid")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Picker("Axis", selection: $fillBetweenAxis) {
                            Text("Sag").tag(0)
                            Text("Cor").tag(1)
                            Text("Ax").tag(2)
                        }
                        .labelsHidden()
                        .frame(width: 74)
                    }

                    Button {
                        let before = vm.labeling.undoDepth
                        let filled = vm.labeling.fillBetweenSlicesActive(axis: fillBetweenAxis)
                        vm.recordLabelEditIfChanged(named: "Fill between slices", beforeUndoDepth: before)
                        vm.statusMessage = "Interpolated \(filled) voxels between labeled slices"
                    } label: {
                        Label("Fill Between Slices", systemImage: "square.stack.3d.forward.dottedline")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Divider()

                    Text("Islands").font(.subheadline)
                    Stepper("Minimum: \(islandMinimumVoxels) voxels",
                            value: $islandMinimumVoxels,
                            in: 1...100_000)
                        .font(.system(size: 11))
                    HStack {
                        Button {
                            let before = vm.labeling.undoDepth
                            let removed = vm.labeling.keepLargestIslandActive()
                            vm.recordLabelEditIfChanged(named: "Keep largest island", beforeUndoDepth: before)
                            vm.statusMessage = "Removed \(removed) voxels outside the largest island"
                        } label: {
                            Label("Keep Largest", systemImage: "circle.dashed.inset.filled")
                                .frame(maxWidth: .infinity)
                        }
                        Button {
                            let before = vm.labeling.undoDepth
                            let removed = vm.labeling.removeSmallIslandsActive(minVoxels: islandMinimumVoxels)
                            vm.recordLabelEditIfChanged(named: "Remove small islands", beforeUndoDepth: before)
                            vm.statusMessage = "Removed \(removed) small-island voxels"
                        } label: {
                            Label("Remove Small", systemImage: "minus.circle")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if let map = vm.labeling.activeLabelMap, map.classes.count > 1 {
                        Divider()
                        Text("Logical").font(.subheadline)
                        Picker("Source", selection: logicalSourceBinding(for: map)) {
                            ForEach(map.classes.filter { $0.labelID != vm.labeling.activeClassID }) { cls in
                                Text(cls.name).tag(cls.labelID)
                            }
                        }
                        HStack {
                            Button {
                                applyLogical(.union)
                            } label: {
                                Label("Union", systemImage: "plus.square.on.square")
                                    .frame(maxWidth: .infinity)
                            }
                            Button {
                                applyLogical(.replace)
                            } label: {
                                Label("Replace", systemImage: "arrow.triangle.2.circlepath")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                Divider()

                // ── Region statistics ──
                if let map = vm.labeling.activeLabelMap,
                   let cls = map.classInfo(id: vm.labeling.activeClassID) {
                    Group {
                        Text("Statistics: \(cls.name)")
                            .font(.headline)

                        if let report = vm.lastVolumeMeasurementReport,
                           report.className == cls.name {
                            if report.voxelCount == 0 {
                                Text("No voxels in this class")
                                    .font(.caption).foregroundColor(.secondary)
                            } else {
                                StatRow("Voxels", "\(report.voxelCount)")
                                StatRow(report.source == .petSUV ? "TTV / MTV" : "Volume",
                                        String(format: "%.1f cm³", report.volumeMM3 / 1000))
                                StatRow("Mean", String(format: "%.1f", report.mean))
                                StatRow("Max",  String(format: "%.1f", report.max))
                                StatRow("Min",  String(format: "%.1f", report.min))
                                StatRow("Std",  String(format: "%.1f", report.std))
                                if let suvMax = report.suvMax {
                                    StatRow("SUV max", String(format: "%.2f", suvMax))
                                }
                                if let suvMean = report.suvMean {
                                    StatRow("SUV mean", String(format: "%.2f", suvMean))
                                }
                                if let tlg = report.tlg {
                                    StatRow("TLG", String(format: "%.1f g·mL⁻¹·mL", tlg))
                                }
                            }
                        } else {
                            Text("Not measured yet.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Button {
                            vm.startActiveVolumeMeasurement(method: .activeLabel,
                                                            thresholdSummary: "Active label")
                        } label: {
                            Label("Refresh Stats", systemImage: "chart.bar")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(vm.isVolumeOperationRunning)
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
                            requestActiveConversion(exportFormat)
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(vm.labeling.activeLabelMap == nil)
                    }

                    Menu {
                        ForEach(LabelIO.Format.allCases) { format in
                            Button(format.rawValue) { requestActiveConversion(format) }
                        }
                    } label: {
                        Label("Convert Active Label", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(vm.labeling.activeLabelMap == nil || vm.currentVolume == nil)

                    Button {
                        showingFormatGuide = true
                    } label: {
                        Label("Format Guide", systemImage: "info.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Menu {
                        Button("Summary CSV…") { exportLabelData(.csv) }
                        Button("Summary TSV…") { exportLabelData(.tsv) }
                        Button("Full JSON…") { exportLabelData(.json) }
                        Button("Full XML…") { exportLabelData(.xml) }
                    } label: {
                        Label("Export Label Data", systemImage: "tablecells")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(vm.labeling.activeLabelMap == nil)

                    Divider()
                    Text("Surface Mesh").font(.subheadline)
                    Picker("Mesh", selection: $meshExportFormat) {
                        ForEach(MarchingCubesMeshExporter.Format.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                    Stepper("Smooth: \(meshSmoothingIterations)",
                            value: $meshSmoothingIterations,
                            in: 0...5)
                        .font(.system(size: 11))
                    HStack {
                        Button {
                            exportActiveSurfaceMesh()
                        } label: {
                            Label("Active Surface", systemImage: "cube.transparent")
                                .frame(maxWidth: .infinity)
                        }
                        Button {
                            exportAllSurfaceMeshes()
                        } label: {
                            Label("All Surfaces", systemImage: "shippingbox")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(vm.labeling.activeLabelMap == nil || vm.currentVolume == nil)

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
        .sheet(isPresented: $showingFormatGuide) {
            AnnotationFormatGuideSheet()
        }
        .sheet(item: $pendingConversion) { request in
            ConversionWarningSheet(
                format: request.format,
                warnings: conversionWarnings(for: request.format),
                onCancel: { pendingConversion = nil },
                onContinue: {
                    pendingConversion = nil
                    performActiveConversion(request.format)
                }
            )
        }
        .fileExporter(
            isPresented: $showingExporter,
            document: LabelDocumentRef(),
            contentType: .data,
            defaultFilename: defaultExportFilename
        ) { result in
            if case .success(let url) = result,
               let v = vm.currentVolume {
                do {
                    try vm.labeling.saveActiveLabel(to: url,
                                                   format: exportFormat,
                                                   parentVolume: v,
                                                   annotations: vm.annotations)
                    vm.statusMessage = "Saved labels to \(url.lastPathComponent)"
                } catch {
                    vm.statusMessage = "Label save failed: \(error.localizedDescription)"
                }
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
            do {
                let imported = try vm.labeling.loadLabel(from: url, parentVolume: v)
                if !imported.annotations.isEmpty {
                    vm.annotations = imported.annotations
                }
                vm.statusMessage = "Loaded labels from \(url.lastPathComponent)"
            } catch {
                vm.statusMessage = "Label import failed: \(error.localizedDescription)"
            }
        }
    }

    private var volumeMeasurementTools: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Volume Measurement")
                    .font(.headline)
                Spacer()
                Menu {
                    Button {
                        vm.startActiveVolumeMeasurement(
                            method: .activeLabel,
                            thresholdSummary: "Active PET label",
                            preferPET: true
                        )
                    } label: {
                        Label("Measure PET / SUV", systemImage: "flame")
                    }
                    Button {
                        vm.startActiveVolumeMeasurement(
                            method: .activeLabel,
                            thresholdSummary: "Active CT label",
                            preferPET: false
                        )
                    } label: {
                        Label("Measure CT / HU", systemImage: "cube")
                    }
                } label: {
                    Label("Measure", systemImage: "chart.bar.doc.horizontal")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .disabled(vm.labeling.activeLabelMap == nil || vm.isVolumeOperationRunning)
            }

            Text("PET tools write SUV-derived MTV/TLG into the active label. CT tools write HU-derived volume masks into the same editable label map.")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Label("PET MTV / TLG", systemImage: "flame")
                    .font(.system(size: 12, weight: .semibold))

                HStack {
                    Text("SUV ≥")
                    Slider(value: $vm.labeling.thresholdValue, in: 0...50, step: 0.1)
                    Text(String(format: "%.1f", vm.labeling.thresholdValue))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 42, alignment: .trailing)
                }

                HStack {
                    Button {
                        vm.startThresholdActiveLabel(atOrAbove: vm.labeling.thresholdValue)
                    } label: {
                        Label("Fixed SUV", systemImage: "greaterthan.circle")
                            .frame(maxWidth: .infinity)
                    }

                    Button {
                        vm.startPercentOfMaxActiveLabelWholeVolume(percent: vm.labeling.percentOfMax)
                    } label: {
                        Label("% SUVmax", systemImage: "percent")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(vm.isVolumeOperationRunning)

                HStack {
                    Text("% max")
                    Slider(value: $vm.labeling.percentOfMax, in: 0.1...0.9, step: 0.01)
                    Text(String(format: "%.0f%%", vm.labeling.percentOfMax * 100))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 42, alignment: .trailing)
                }

                Stepper("Seed box: \(vm.labeling.percentOfMaxSearchRadius) voxels",
                        value: $vm.labeling.percentOfMaxSearchRadius,
                        in: 5...160)
                    .font(.system(size: 11))
                    .help("Local %SUVmax seed search radius for threshold clicks.")
            }
            .padding(8)
            .background(Color.orange.opacity(0.08))
            .cornerRadius(6)

            VStack(alignment: .leading, spacing: 8) {
                Label("CT HU Volumetry", systemImage: "cube")
                    .font(.system(size: 12, weight: .semibold))

                Picker("Preset", selection: $selectedHUPresetID) {
                    ForEach(HUThresholdPreset.presets) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
                .onChange(of: selectedHUPresetID) { _, id in
                    guard let preset = HUThresholdPreset.presets.first(where: { $0.id == id }) else { return }
                    ctLowerHU = preset.lower
                    ctUpperHU = preset.upper
                }

                if let preset = HUThresholdPreset.presets.first(where: { $0.id == selectedHUPresetID }) {
                    Text(preset.note)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                SmallNumberRow("Lower HU", value: $ctLowerHU)
                SmallNumberRow("Upper HU", value: $ctUpperHU)

                HStack {
                    Button {
                        vm.startThresholdActiveCTLabel(lowerHU: ctLowerHU, upperHU: ctUpperHU)
                    } label: {
                        Label("Apply HU Range", systemImage: "ruler")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.isVolumeOperationRunning)

                    Button {
                        let preset = HUThresholdPreset.presets.first(where: { $0.id == selectedHUPresetID }) ?? HUThresholdPreset.presets[1]
                        ctLowerHU = preset.lower
                        ctUpperHU = preset.upper
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.small)
            }
            .padding(8)
            .background(Color.cyan.opacity(0.07))
            .cornerRadius(6)

            if let report = vm.lastVolumeMeasurementReport {
                VolumeMeasurementReportView(report: report)
            }

            radiomicsTools

            HStack {
                Button(role: .destructive) {
                    let before = vm.labeling.undoDepth
                    let cleared = vm.labeling.resetActiveClass()
                    vm.recordLabelEditIfChanged(named: "Reset active class", beforeUndoDepth: before)
                    vm.startActiveVolumeMeasurement()
                    vm.statusMessage = "Reset active class (\(cleared) voxels cleared)"
                } label: {
                    Label("Reset Class", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .disabled(vm.labeling.activeLabelMap == nil || vm.isVolumeOperationRunning)

                Button(role: .destructive) {
                    vm.resetEditableChanges()
                } label: {
                    Label("Reset Edits", systemImage: "arrow.counterclockwise.circle")
                        .frame(maxWidth: .infinity)
                }
                .disabled(vm.isVolumeOperationRunning)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var radiomicsTools: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Radiomics", systemImage: "waveform.path.ecg.rectangle")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if let report = vm.lastRadiomicsFeatureReport {
                    RadiomicsExportMenu(report: report)
                }
            }

            HStack {
                Button {
                    _ = vm.extractActiveRadiomics(preferPET: true)
                } label: {
                    Label("PET SUV", systemImage: "flame")
                        .frame(maxWidth: .infinity)
                }

                Button {
                    _ = vm.extractActiveRadiomics(preferPET: false)
                } label: {
                    Label("CT HU", systemImage: "cube")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(vm.labeling.activeLabelMap == nil)

            if let report = vm.lastRadiomicsFeatureReport {
                RadiomicsFeatureReportView(report: report)
            }
        }
        .padding(8)
        .background(Color.indigo.opacity(0.07))
        .cornerRadius(6)
    }

    private var defaultExportFilename: String {
        defaultExportFilename(for: exportFormat)
    }

    private func defaultExportFilename(for format: LabelIO.Format) -> String {
        switch format {
        case .dicomSeg:
            return "labels.seg.dcm"
        case .dicomRTStruct:
            return "labels.rtstruct.dcm"
        case .slicerSeg:
            return "labels.seg.nrrd"
        case .niftiGz:
            return "labels.nii.gz"
        default:
            let ext = format.fileExtensions.first ?? "dat"
            return "labels.\(ext)"
        }
    }

    private func requestActiveConversion(_ format: LabelIO.Format) {
        exportFormat = format
        if conversionWarnings(for: format).isEmpty {
            performActiveConversion(format)
        } else {
            pendingConversion = PendingLabelConversion(format: format)
        }
    }

    private func conversionWarnings(for format: LabelIO.Format) -> [AnnotationConversionWarning] {
        let map = vm.labeling.activeLabelMap
        let hasVoxels = map?.voxels.contains { $0 != 0 } ?? false
        return format.conversionWarnings(
            hasVoxels: hasVoxels,
            hasAnnotations: !vm.annotations.isEmpty,
            hasLandmarks: !vm.labeling.landmarks.isEmpty
        )
    }

    private func performActiveConversion(_ format: LabelIO.Format) {
        exportFormat = format
        #if canImport(AppKit)
        guard let volume = vm.currentVolume else {
            vm.statusMessage = "Load a reference volume before exporting labels."
            return
        }
        guard vm.labeling.activeLabelMap != nil else {
            vm.statusMessage = "No active label map to export."
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultExportFilename(for: format)
        panel.allowedContentTypes = [.data]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try vm.labeling.saveActiveLabel(to: url,
                                           format: format,
                                           parentVolume: volume,
                                           annotations: vm.annotations)
            vm.statusMessage = "Converted labels to \(url.lastPathComponent)"
        } catch {
            vm.statusMessage = "Label conversion failed: \(error.localizedDescription)"
        }
        #else
        showingExporter = true
        #endif
    }

    private func logicalSourceBinding(for map: LabelMap) -> Binding<UInt16> {
        Binding(
            get: {
                if logicalSourceClassID != 0,
                   logicalSourceClassID != vm.labeling.activeClassID,
                   map.classes.contains(where: { $0.labelID == logicalSourceClassID }) {
                    return logicalSourceClassID
                }
                return map.classes.first { $0.labelID != vm.labeling.activeClassID }?.labelID ?? 0
            },
            set: { logicalSourceClassID = $0 }
        )
    }

    private func applyLogical(_ operation: LabelLogicalOperation) {
        guard let map = vm.labeling.activeLabelMap else { return }
        let sourceID = logicalSourceBinding(for: map).wrappedValue
        let before = vm.labeling.undoDepth
        let changed = vm.labeling.applyLogicalOperation(sourceClassID: sourceID, operation: operation)
        vm.recordLabelEditIfChanged(named: operation.displayName, beforeUndoDepth: before)
        vm.statusMessage = "\(operation.displayName) changed \(changed) voxels"
    }
}

private struct PendingLabelConversion: Identifiable {
    let format: LabelIO.Format
    var id: String { format.id }
}

private struct ConversionWarningSheet: View {
    let format: LabelIO.Format
    let warnings: [AnnotationConversionWarning]
    let onCancel: () -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(format.rawValue)
                        .font(.title3.weight(.semibold))
                    Text(format.usageDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(warnings) { warning in
                        ConversionWarningRow(warning: warning)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Stored in this format")
                            .font(.system(size: 12, weight: .semibold))
                        FeatureWrap(features: format.storedFeatures)
                    }
                    .padding(.top, 4)

                    Text(format.conversionNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Cancel") { onCancel() }
                Spacer()
                Button {
                    onContinue()
                } label: {
                    Label("Continue Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(minWidth: 440, idealWidth: 520, maxWidth: 620, minHeight: 360)
    }
}

private struct ConversionWarningRow: View {
    let warning: AnnotationConversionWarning

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(warning.severity.rawValue)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(severityColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(severityColor.opacity(0.12))
                    .cornerRadius(4)
                Text(warning.title)
                    .font(.system(size: 12, weight: .semibold))
            }
            Text(warning.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            FeatureWrap(features: warning.affectedFeatures)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.07))
        .cornerRadius(6)
    }

    private var severityColor: Color {
        switch warning.severity {
        case .info:
            return .blue
        case .caution:
            return .orange
        case .dataLoss, .unsupported:
            return .red
        }
    }
}

private struct FeatureWrap: View {
    let features: [AnnotationPayloadFeature]

    private let columns = [
        GridItem(.adaptive(minimum: 108), spacing: 4, alignment: .leading)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            ForEach(features) { feature in
                Text(feature.rawValue)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.10))
                    .cornerRadius(4)
            }
        }
    }
}

private struct AnnotationFormatGuideSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showingGuideOnly = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Label / Annotation Formats")
                    .font(.title3.weight(.semibold))
                Spacer()
                Toggle("Include guide-only", isOn: $showingGuideOnly)
                Button("Done") { dismiss() }
            }

            List {
                Section("Tracer supported") {
                    ForEach(AnnotationFormatCatalog.supportedEntries) { entry in
                        AnnotationFormatGuideRow(entry: entry)
                    }
                }
                if showingGuideOnly {
                    Section("Common external formats") {
                        ForEach(AnnotationFormatCatalog.guideOnlyEntries) { entry in
                            AnnotationFormatGuideRow(entry: entry)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .padding(16)
        .frame(minWidth: 680, idealWidth: 760, maxWidth: 900, minHeight: 520)
    }
}

private struct AnnotationFormatGuideRow: View {
    let entry: AnnotationFormatGuideEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(entry.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(entry.support.rawValue)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(supportColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(supportColor.opacity(0.12))
                    .cornerRadius(4)
                Spacer()
                Text(entry.extensions.map { ".\($0)" }.joined(separator: ", "))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Text(entry.usage)
                .font(.caption)
                .foregroundStyle(.secondary)
            FeatureWrap(features: entry.storedFeatures)
            Text(entry.conversionNote)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
    }

    private var supportColor: Color {
        switch entry.support {
        case .nativeReadWrite:
            return .green
        case .exportOnly, .sidecar:
            return .orange
        case .guideOnly:
            return .secondary
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

private struct SmallNumberRow: View {
    let label: String
    @Binding var value: Double

    init(_ label: String, value: Binding<Double>) {
        self.label = label
        self._value = value
    }

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            TextField("", value: $value, formatter: Self.formatter)
                .font(.system(size: 11, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(width: 86)
                .textFieldStyle(.roundedBorder)
        }
    }

    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return formatter
    }()
}

private struct VolumeMeasurementReportView: View {
    let report: VolumeMeasurementReport

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(report.source.rawValue, systemImage: report.source == .petSUV ? "flame" : "cube")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(report.method.rawValue)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Text(report.className)
                .font(.system(size: 11, weight: .medium))
            Text(report.thresholdSummary)
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            StatRow("Voxels", "\(report.voxelCount)")
            StatRow(report.source == .petSUV ? "TTV / MTV" : "Volume",
                    String(format: "%.2f mL", report.volumeML))
            StatRow(report.source == .ctHU ? "Mean HU" : "Mean", String(format: "%.2f", report.mean))
            StatRow("Range", String(format: "%.1f…%.1f", report.min, report.max))
            if let suvMax = report.suvMax {
                StatRow("SUVmax", String(format: "%.2f", suvMax))
            }
            if let suvMean = report.suvMean {
                StatRow("SUVmean", String(format: "%.2f", suvMean))
            }
            if let tlg = report.tlg {
                StatRow("TLG", String(format: "%.1f", tlg))
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(6)
    }
}

private struct RadiomicsFeatureReportView: View {
    let report: RadiomicsFeatureReport

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(report.source.rawValue)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text("\(report.featureCount) features")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Text(report.className)
                .font(.system(size: 11, weight: .medium))
            StatRow("Bounds", "\(report.bounds.width)x\(report.bounds.height)x\(report.bounds.depth)")
            ForEach(report.topPreviewFeatures, id: \.0) { name, value in
                StatRow(shortFeatureName(name), String(format: "%.4g", value))
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(6)
    }

    private func shortFeatureName(_ name: String) -> String {
        name
            .replacingOccurrences(of: "original_firstorder_", with: "")
            .replacingOccurrences(of: "original_shape_", with: "")
            .replacingOccurrences(of: "original_glcm_", with: "GLCM ")
    }
}

private struct RadiomicsExportMenu: View {
    let report: RadiomicsFeatureReport

    var body: some View {
        Menu {
            Button("Export JSON…") { export(.json) }
            Button("Export CSV…") { export(.csv) }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
    }

    private enum Format { case json, csv }

    private func export(_ format: Format) {
        #if canImport(AppKit)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "radiomics-\(report.source == .petSUV ? "pet" : "ct").\(format == .json ? "json" : "csv")"
        panel.allowedContentTypes = [format == .json ? .json : .commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = format == .json ? try report.jsonData() : report.csvData
            try data.write(to: url, options: [.atomic])
        } catch {
            NSLog("Radiomics export failed: \(error)")
        }
        #endif
    }
}

private extension LabelingPanel {
    enum LabelDataExportFormat {
        case json, csv, tsv, xml

        var fileExtension: String {
            switch self {
            case .json: return "json"
            case .csv: return "csv"
            case .tsv: return "tsv"
            case .xml: return "xml"
            }
        }

        var contentType: UTType {
            switch self {
            case .json: return .json
            case .csv: return .commaSeparatedText
            case .tsv: return .plainText
            case .xml: return .xml
            }
        }
    }

    func exportLabelData(_ format: LabelDataExportFormat) {
        #if canImport(AppKit)
        guard let report = vm.activeLabelDataExportReport() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "label-data.\(format.fileExtension)"
        panel.allowedContentTypes = [format.contentType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data: Data
            switch format {
            case .json:
                data = try report.jsonData()
            case .csv:
                data = report.csvData
            case .tsv:
                data = report.tsvData
            case .xml:
                data = report.xmlData
            }
            try data.write(to: url, options: [.atomic])
            vm.statusMessage = "Exported label data to \(url.lastPathComponent)"
        } catch {
            vm.statusMessage = "Label data export failed: \(error.localizedDescription)"
        }
        #endif
    }

    func exportActiveSurfaceMesh() {
        #if canImport(AppKit)
        guard let volume = vm.currentVolume else {
            vm.statusMessage = "Load a reference volume before exporting a mesh."
            return
        }
        let className = vm.labeling.activeLabelMap?
            .classInfo(id: vm.labeling.activeClassID)?
            .name ?? "active-label"
        let safeName = className
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .lowercased()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(safeName.isEmpty ? "active-label" : safeName).\(meshExportFormat.fileExtension)"
        panel.allowedContentTypes = [.data]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if let mesh = try vm.labeling.exportActiveMesh(
                to: url,
                format: meshExportFormat,
                parentVolume: volume,
                smoothingIterations: meshSmoothingIterations
            ) {
                vm.statusMessage = "Exported \(mesh.className) mesh: \(mesh.triangleCount) triangles"
            }
        } catch {
            vm.statusMessage = "Mesh export failed: \(error.localizedDescription)"
        }
        #endif
    }

    func exportAllSurfaceMeshes() {
        #if canImport(AppKit)
        guard let volume = vm.currentVolume else {
            vm.statusMessage = "Load a reference volume before exporting meshes."
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let meshes = try vm.labeling.exportAllMeshes(
                to: url,
                format: meshExportFormat,
                parentVolume: volume,
                smoothingIterations: meshSmoothingIterations
            )
            let triangles = meshes.reduce(0) { $0 + $1.triangleCount }
            vm.statusMessage = "Exported \(meshes.count) mesh files (\(triangles) triangles)"
        } catch {
            vm.statusMessage = "Mesh export failed: \(error.localizedDescription)"
        }
        #endif
    }
}

// MARK: - Document wrapper for file export

private struct LabelDocumentRef: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    static var writableContentTypes: [UTType] { [.data] }

    init() {}

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // The actual file is written in the .fileExporter result handler.
        return FileWrapper(regularFileWithContents: Data())
    }
}
