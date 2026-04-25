import SwiftUI
import CoreGraphics
import simd
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// A single 2D slice view (axial, sagittal, or coronal) with full tool support.
public struct SliceView: View {
    @EnvironmentObject var vm: ViewerViewModel
    let axis: Int
    let title: String
    let displayMode: SliceDisplayMode
    let paneIndex: Int?

    // Per-view interaction state. Persistent zoom/pan lives in ViewerViewModel
    // so it can be linked across the full hanging protocol when requested.
    @State private var dragStartPan: CGSize?
    @State private var gestureStartZoom: CGFloat?
    @State private var viewportBeforeInteraction: ViewportTransformState?
    @State private var windowLevelBeforeInteraction: (window: Double, level: Double)?
    @State private var labelUndoDepthBeforeInteraction: Int?
    @State private var measurementPoints: [CGPoint] = []
    @State private var activeMeasurement: Annotation?
    @State private var dragStart: CGPoint?
    @State private var lastPaintPoint: (Int, Int)?
    #if os(macOS)
    @State private var wheelAccumulator: CGFloat = 0
    #endif

    /// Voxel under the mouse cursor — drives the live intensity / SUV /
    /// world-coordinate badge in the upper-right of the slice view.
    /// `nil` when the cursor has left the image area.
    @State private var hoverSample: HoverSample?

    public init(axis: Int,
                title: String,
                displayMode: SliceDisplayMode = .fused,
                paneIndex: Int? = nil) {
        self.axis = axis
        self.title = title
        self.displayMode = displayMode
        self.paneIndex = paneIndex
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geo in
                ZStack {
                    TracerTheme.viewportBackground

                    if let cg = vm.makeImage(for: axis, mode: displayMode) {
                        let imgW = CGFloat(cg.width)
                        let imgH = CGFloat(cg.height)
                        let fit = min(geo.size.width / imgW, geo.size.height / imgH) * zoom

                        // Base image
                        Image(decorative: cg, scale: 1.0)
                            .resizable()
                            .interpolation(.medium)
                            .frame(width: imgW * fit, height: imgH * fit)
                            .offset(pan)

                        // Overlay image (if fusion active)
                        if let ov = vm.makeOverlayImage(for: axis, mode: displayMode) {
                            Image(decorative: ov, scale: 1.0)
                                .resizable()
                                .interpolation(.medium)
                                .frame(width: imgW * fit, height: imgH * fit)
                                .offset(pan)
                        }

                        // Label overlay
                        if let lbl = vm.makeLabelImage(for: axis, mode: displayMode) {
                            Image(decorative: lbl, scale: 1.0)
                                .resizable()
                                .interpolation(.none)
                                .frame(width: imgW * fit, height: imgH * fit)
                                .offset(pan)
                        }

                        // Orthogonal slice cross-reference lines. These are
                        // the useful part of linked MPR navigation: scrolling
                        // one plane updates its own slice, while the other
                        // planes show exactly where that slice intersects.
                        crossReferenceCanvas(scale: fit, imageSize: CGSize(width: imgW, height: imgH))
                            .frame(width: imgW * fit, height: imgH * fit)
                            .offset(pan)

                        // Measurements overlay
                        measurementCanvas(scale: fit, imageSize: CGSize(width: imgW, height: imgH))
                            .frame(width: imgW * fit, height: imgH * fit)
                            .offset(pan)

                        // Orientation letters
                        orientationMarkers
                            .padding(12)
                    } else {
                        Text(vm.currentVolume == nil
                             ? "Load a volume to display"
                             : "Rendering…")
                            .foregroundColor(.gray)
                    }

                    // Info label (top-left) and hover badge (top-right).
                    VStack {
                        HStack(alignment: .top) {
                            infoText
                            Spacer()
                            if let sample = hoverSample {
                                hoverBadge(sample)
                                    .transition(.opacity)
                            }
                        }
                        Spacer()
                    }
                    .padding(6)

                    if let badge = fusionLayerBadge {
                        VStack {
                            Spacer()
                            HStack {
                                badge
                                Spacer()
                            }
                        }
                        .padding(8)
                    }
                }
                .clipped()
                .contentShape(Rectangle())
                .gesture(magnificationGesture())
                .gesture(dragGesture(geo: geo))
                .onTapGesture(count: 2) { resetView() }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoverSample = sampleVoxel(at: location, in: geo.size)
                    case .ended:
                        hoverSample = nil
                    }
                }
                .contextMenu { contextMenuItems() }
                #if os(macOS)
                .background(SliceScrollWheelBridge { event in
                    handleScrollWheel(event)
                })
                .onAppear { NSCursor.setHiddenUntilMouseMoves(false) }
                #endif
            }
            .background(TracerTheme.viewportBackground)
            .overlay(
                Rectangle()
                    .stroke(TracerTheme.hairline, lineWidth: 1)
            )
        }
        .background(TracerTheme.panelBackground)
    }

    private var viewportKey: Int {
        paneIndex ?? (100 + axis)
    }

    private var zoom: CGFloat {
        CGFloat(vm.viewportTransform(for: viewportKey).zoom)
    }

    private var pan: CGSize {
        let state = vm.viewportTransform(for: viewportKey)
        return CGSize(width: state.panX, height: state.panY)
    }

    private func setZoom(_ value: CGFloat) {
        vm.setViewportZoom(Double(value), for: viewportKey)
    }

    private func setPan(_ value: CGSize) {
        vm.setViewportPan(x: Double(value.width), y: Double(value.height), for: viewportKey)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(TracerTheme.accentBright)
                .help("\(title) view\nScroll wheel or slider to navigate slices")

            if let paneIndex {
                paneControls(index: paneIndex)
            }

            Spacer()

            HoverIconButton(
                systemImage: "circle.righthalf.filled",
                tooltip: "Invert Colors (all views)\n"
                       + "Toggles grayscale inversion — useful for reading MRI\n"
                       + "or X-ray images in the radiological convention.",
                isActive: vm.invertColors
            ) {
                vm.setInvertColors(!vm.invertColors)
            }

            HoverIconButton(
                systemImage: "rectangle.on.rectangle.angled",
                tooltip: "Reset view (zoom + pan)\nDouble-click the view also resets.\nWhen linked, resets all panes."
            ) {
                resetView()
            }

            sliceScrubber
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(TracerTheme.headerBackground)
    }

    private var sliceScrubber: some View {
        HStack(spacing: 4) {
            if let v = vm.volumeForDisplayMode(displayMode) {
                let maxIdx: Int = {
                    switch axis {
                    case 0: return v.width - 1
                    case 1: return v.height - 1
                    default: return v.depth - 1
                    }
                }()
                let currentIndex = max(0, min(maxIdx, vm.sliceIndices[axis]))
                let binding = Binding<Double>(
                    get: { Double(currentIndex) },
                    set: { vm.setSlice(axis: axis, index: Int($0)) }
                )
                Text("\(currentIndex + 1)/\(maxIdx + 1)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray)
                    .frame(width: 60, alignment: .trailing)
                Slider(value: binding, in: 0...Double(maxIdx), step: 1)
                    .frame(maxWidth: 120)
            }
        }
    }

    // MARK: - Info overlay

    private var infoText: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let v = vm.volumeForDisplayMode(displayMode) {
                let (w, h) = sliceDimensions(for: v)
                Text("\(w)×\(h)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray)
                Text(windowLevelInfo(for: v))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray)
                Text(String(format: "Zoom: %.0f%%", zoom * 100))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray)
            }
        }
        .padding(4)
        .background(Color.black.opacity(0.5))
        .cornerRadius(4)
    }

    private func paneControls(index: Int) -> some View {
        HStack(spacing: 3) {
            Picker("", selection: Binding(
                get: { vm.hangingPanes.indices.contains(index) ? vm.hangingPanes[index].kind : .fused },
                set: { vm.setHangingPaneKind(index: index, kind: $0) }
            )) {
                ForEach(HangingPaneKind.allCases) { kind in
                    Label(kind.displayName, systemImage: kind.systemImage).tag(kind)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 88)
            .controlSize(.mini)

            Picker("", selection: Binding(
                get: { vm.hangingPanes.indices.contains(index) ? vm.hangingPanes[index].plane : .axial },
                set: { vm.setHangingPanePlane(index: index, plane: $0) }
            )) {
                ForEach(SlicePlane.allCases) { plane in
                    Text(plane.shortName).tag(plane)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 58)
            .controlSize(.mini)
        }
    }

    private func windowLevelInfo(for volume: ImageVolume) -> String {
        if Modality.normalize(volume.modality) == .PT || displayMode == .petOnly {
            return String(format: "SUV %.1f–%.1f", vm.petOverlayRangeMin, vm.petOverlayRangeMax)
        }
        return "W: \(Int(vm.window))  L: \(Int(vm.level))"
    }

    private var fusionLayerBadge: AnyView? {
        guard displayMode == .fused, let pair = vm.fusion, pair.overlayVisible else { return nil }
        let overlay = Modality.normalize(pair.overlayVolume.modality).displayName
        let base = Modality.normalize(pair.baseVolume.modality).displayName
        let opacity = Int(pair.opacity * 100)
        return AnyView(
            HStack(spacing: 6) {
                Image(systemName: "square.3.layers.3d.down.right")
                    .foregroundColor(TracerTheme.accentBright)
                Text("Top \(overlay) \(opacity)%")
                    .foregroundColor(.white)
                Text("over \(base)")
                    .foregroundColor(.secondary)
                Circle()
                    .fill(Color.orange)
                    .frame(width: 7, height: 7)
                Text(pair.colormap.displayName)
                    .foregroundColor(.secondary)
            }
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .padding(.vertical, 4)
            .padding(.horizontal, 7)
            .background(Color.black.opacity(0.58))
            .cornerRadius(5)
        )
    }

    private func sliceDimensions(for v: ImageVolume) -> (Int, Int) {
        switch axis {
        case 0: return (v.height, v.depth)
        case 1: return (v.width, v.depth)
        default: return (v.width, v.height)
        }
    }

    // MARK: - Hover badge

    /// Live voxel sample under the cursor. Used to populate the top-right
    /// "hover badge" with raw intensity, SUV (when viewing PET), world
    /// coordinates, and — when a label map is active — the class name.
    struct HoverSample: Equatable {
        let voxelX: Int
        let voxelY: Int
        let voxelZ: Int
        let rawIntensity: Float
        let suv: Double?
        let world: SIMD3<Double>
        let className: String?
    }

    private func sampleVoxel(at location: CGPoint, in viewSize: CGSize) -> HoverSample? {
        guard let volume = vm.volumeForDisplayMode(displayMode),
              let cg = vm.makeImage(for: axis, mode: displayMode) else {
            return nil
        }
        let imgW = CGFloat(cg.width)
        let imgH = CGFloat(cg.height)
        let baseFit = min(viewSize.width / imgW, viewSize.height / imgH)
        let fit = baseFit * zoom
        guard fit > 0 else { return nil }

        // Map screen point → displayed image point → voxel coordinates.
        let imageOriginX = (viewSize.width - imgW * fit) / 2 + pan.width
        let imageOriginY = (viewSize.height - imgH * fit) / 2 + pan.height
        let localX = (location.x - imageOriginX) / fit
        let localY = (location.y - imageOriginY) / fit
        guard localX >= 0, localX < imgW, localY >= 0, localY < imgH else {
            return nil
        }

        var px = Int(localX.rounded(.down))
        var py = Int(localY.rounded(.down))
        let transform = vm.displayTransform(for: axis, volume: volume)
        if transform.flipHorizontal {
            px = Int(imgW) - 1 - px
        }
        if transform.flipVertical {
            py = Int(imgH) - 1 - py
        }
        let (vz, vy, vx) = volumeVoxel(px: px, py: py, sliceIndex: vm.sliceIndices[axis])
        guard vx >= 0, vx < volume.width,
              vy >= 0, vy < volume.height,
              vz >= 0, vz < volume.depth else {
            return nil
        }

        let linear = vz * volume.height * volume.width + vy * volume.width + vx
        let raw = volume.pixels[linear]

        let isPET = Modality.normalize(volume.modality) == .PT
        let suv: Double? = isPET
            ? vm.suvValue(rawStoredValue: Double(raw), volume: volume)
            : nil

        let world = volume.worldPoint(
            voxel: SIMD3<Double>(Double(vx), Double(vy), Double(vz))
        )

        // Label class name (if an active label map is visible).
        var className: String?
        if let map = vm.labeling.activeLabelMap, map.visible,
           map.width == volume.width,
           map.height == volume.height,
           map.depth == volume.depth {
            let classID = map.voxels[linear]
            if classID != 0,
               let cls = map.classInfo(id: classID) {
                className = cls.name
            }
        }

        return HoverSample(
            voxelX: vx, voxelY: vy, voxelZ: vz,
            rawIntensity: raw,
            suv: suv,
            world: world,
            className: className
        )
    }

    private func volumeVoxel(px: Int, py: Int, sliceIndex: Int) -> (Int, Int, Int) {
        // Inverse of `vm.makeImage(for:)` axis mapping.
        switch axis {
        case 0:  return (py, px, sliceIndex)  // z, y, x
        case 1:  return (py, sliceIndex, px)
        default: return (sliceIndex, py, px)
        }
    }

    // MARK: - Context menu

    /// Right-click / long-press context menu. Keeps itself terse: four
    /// verbs tops. More granular controls live in the ControlsPanel tabs.
    @ViewBuilder
    private func contextMenuItems() -> some View {
        if let sample = hoverSample {
            Section("Cursor") {
                Text(String(format: "Voxel (%d, %d, %d)",
                            sample.voxelX, sample.voxelY, sample.voxelZ))
                Text(String(format: "Raw %.2f", sample.rawIntensity))
                if let suv = sample.suv {
                    Text(String(format: "SUV %.2f", suv))
                }
                if let className = sample.className {
                    Text("Class: \(className)")
                }
                Button("Copy coordinates") {
                    copyToPasteboard(String(format: "%d, %d, %d",
                                            sample.voxelX, sample.voxelY, sample.voxelZ))
                }
                Button("Copy world position (mm)") {
                    copyToPasteboard(String(format: "%.2f, %.2f, %.2f mm",
                                            sample.world.x, sample.world.y, sample.world.z))
                }
            }
        }

        Section("Tools") {
            Button {
                vm.activeTool = .distance
            } label: {
                Label("Distance measurement", systemImage: "ruler")
            }
            Button {
                vm.activeTool = .angle
            } label: {
                Label("Angle measurement", systemImage: "angle")
            }
            Button {
                vm.activeTool = .area
            } label: {
                Label("Area / ROI", systemImage: "skew")
            }
            Button {
                vm.activeTool = .wl
                vm.labeling.labelingTool = .brush
            } label: {
                Label("Brush on active label", systemImage: "paintbrush.pointed.fill")
            }
        }

        Section("View") {
            Button("Reset zoom + pan") { resetView() }
            Button(vm.invertColors ? "Disable inversion" : "Invert colors") {
                vm.setInvertColors(!vm.invertColors)
            }
            Button("Center slices on cursor") {
                if let sample = hoverSample {
                    vm.setSlice(axis: 0, index: sample.voxelX)
                    vm.setSlice(axis: 1, index: sample.voxelY)
                    vm.setSlice(axis: 2, index: sample.voxelZ)
                }
            }
            .disabled(hoverSample == nil)
        }
    }

    private func copyToPasteboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }

    private func hoverBadge(_ sample: HoverSample) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "(%d, %d, %d)",
                        sample.voxelX, sample.voxelY, sample.voxelZ))
                .foregroundColor(.white)
            Text(String(format: "raw %.2f", sample.rawIntensity))
                .foregroundColor(.secondary)
            if let suv = sample.suv {
                Text(String(format: "SUV %.2f", suv))
                    .foregroundColor(.orange)
            }
            Text(String(format: "world %.1f, %.1f, %.1f mm",
                        sample.world.x, sample.world.y, sample.world.z))
                .foregroundColor(.secondary)
            if let className = sample.className {
                Text(className)
                    .foregroundColor(.green)
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(Color.black.opacity(0.55))
        .cornerRadius(4)
    }

    // MARK: - Orientation markers

    private var orientationMarkers: some View {
        let letters = orientationLetters(for: axis)
        return ZStack {
            VStack {
                Text(letters.top).opacity(0.6)
                Spacer()
                Text(letters.bottom).opacity(0.6)
            }
            HStack {
                Text(letters.left).opacity(0.6)
                Spacer()
                Text(letters.right).opacity(0.6)
            }
        }
        .font(.system(size: 12, weight: .bold, design: .monospaced))
        .foregroundColor(.yellow)
    }

    private func orientationLetters(for axis: Int) -> (top: String, bottom: String, left: String, right: String) {
        guard let volume = vm.volumeForDisplayMode(displayMode) else {
            return fallbackOrientationLetters(for: axis)
        }

        let axes = vm.displayAxes(for: axis, volume: volume)
            ?? SliceDisplayTransform.displayAxes(axis: axis, volume: volume)
        let rightVector = axes.right
        let downVector = axes.down

        return (
            top: patientLetter(for: -downVector),
            bottom: patientLetter(for: downVector),
            left: patientLetter(for: -rightVector),
            right: patientLetter(for: rightVector)
        )
    }

    private func fallbackOrientationLetters(for axis: Int) -> (top: String, bottom: String, left: String, right: String) {
        switch axis {
        case 0: return ("H", "F", "A", "P")   // Sagittal
        case 1: return ("H", "F", "R", "L")   // Coronal
        default: return ("A", "P", "R", "L")  // Axial
        }
    }

    private func patientLetter(for vector: SIMD3<Double>) -> String {
        SliceDisplayTransform.patientLetter(for: vector)
    }

    // MARK: - Gestures

    private func magnificationGesture() -> some Gesture {
        // Magnification for pinch-to-zoom
        MagnificationGesture()
            .onChanged { scale in
                if gestureStartZoom == nil {
                    gestureStartZoom = zoom
                    viewportBeforeInteraction = vm.viewportTransform(for: viewportKey)
                }
                let start = gestureStartZoom ?? 1.0
                setZoom(max(0.25, min(10.0, start * scale)))
            }
            .onEnded { _ in
                if let before = viewportBeforeInteraction {
                    vm.recordViewportChange(before: before,
                                            after: vm.viewportTransform(for: viewportKey),
                                            paneKey: viewportKey)
                }
                viewportBeforeInteraction = nil
                gestureStartZoom = nil
            }
    }

    #if os(macOS)
    private func handleScrollWheel(_ event: SliceScrollWheelEvent) {
        let rawDelta = event.rawDeltaY
        guard abs(rawDelta) > 0.01 else { return }

        if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command) {
            let sensitivity = event.hasPreciseScrollingDeltas ? 0.0025 : 0.08
            let factor = max(0.2, 1.0 + Double(rawDelta) * sensitivity)
            let before = vm.viewportTransform(for: viewportKey)
            setZoom(CGFloat(max(0.25, min(10.0, Double(zoom) * factor))))
            vm.recordViewportChange(before: before,
                                    after: vm.viewportTransform(for: viewportKey),
                                    paneKey: viewportKey)
            return
        }

        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 5 : 1
        wheelAccumulator += rawDelta
        let steps = Int(wheelAccumulator / threshold)
        guard steps != 0 else { return }
        wheelAccumulator -= CGFloat(steps) * threshold
        vm.scroll(axis: axis, delta: steps)
    }
    #endif

    private func dragGesture(geo: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let translation = value.translation
                if dragStart == nil { dragStart = value.location }

                // Labeling tools take priority over viewer tools
                if vm.labeling.labelingTool != .none,
                   let v = vm.volumeForDisplayMode(displayMode) {
                    handleLabelingDrag(value: value, volume: v, geo: geo)
                    return
                }

                switch vm.activeTool {
                case .wl:
                    if windowLevelBeforeInteraction == nil {
                        windowLevelBeforeInteraction = (vm.window, vm.level)
                    }
                    if let start = dragStart {
                        let dx = value.location.x - start.x
                        let dy = value.location.y - start.y
                        dragStart = value.location
                        vm.adjustWindowLevel(dw: Double(dx) * 2, dl: -Double(dy) * 2)
                    }
                case .pan:
                    if dragStartPan == nil {
                        dragStartPan = pan
                        viewportBeforeInteraction = vm.viewportTransform(for: viewportKey)
                    }
                    let start = dragStartPan ?? .zero
                    setPan(CGSize(
                        width: start.width + translation.width,
                        height: start.height + translation.height
                    ))
                case .zoom:
                    if gestureStartZoom == nil {
                        gestureStartZoom = zoom
                        viewportBeforeInteraction = vm.viewportTransform(for: viewportKey)
                    }
                    let start = gestureStartZoom ?? 1.0
                    let factor = 1.0 + Double(-translation.height) * 0.005
                    setZoom(CGFloat(max(0.25, min(10.0, Double(start) * factor))))
                case .distance, .angle, .area:
                    break
                }
            }
            .onEnded { value in
                if vm.labeling.labelingTool != .none {
                    vm.labeling.commitVoxelEdit()
                    vm.recordLabelEditIfChanged(named: "Label edit", beforeUndoDepth: labelUndoDepthBeforeInteraction)
                }
                if vm.labeling.labelingTool == .none,
                   isMeasurementTool(vm.activeTool),
                   isTap(value),
                   let volume = vm.volumeForDisplayMode(displayMode) {
                    handleMeasurementTap(at: value.location, volume: volume, geo: geo)
                }
                dragStart = nil
                dragStartPan = nil
                gestureStartZoom = nil
                if let before = viewportBeforeInteraction {
                    vm.recordViewportChange(before: before,
                                            after: vm.viewportTransform(for: viewportKey),
                                            paneKey: viewportKey)
                }
                if let before = windowLevelBeforeInteraction {
                    vm.recordWindowLevelChange(before: before,
                                               after: (vm.window, vm.level))
                }
                viewportBeforeInteraction = nil
                windowLevelBeforeInteraction = nil
                labelUndoDepthBeforeInteraction = nil
                lastPaintPoint = nil
            }
    }

    private func handleLabelingDrag(value: DragGesture.Value, volume: ImageVolume,
                                     geo: GeometryProxy) {
        guard !vm.isVolumeOperationRunning else {
            vm.statusMessage = "Volume operation is running; pan, zoom, scroll, or cancel before editing labels."
            return
        }

        let pixel = mapToImagePixel(point: value.location, volume: volume, geo: geo)
        guard let p = pixel else { return }

        switch vm.labeling.labelingTool {
        case .brush, .eraser:
            let erase = vm.labeling.labelingTool == .eraser
            if lastPaintPoint == nil {
                labelUndoDepthBeforeInteraction = vm.labeling.undoDepth
                vm.labeling.beginVoxelEdit(named: erase ? "Erase stroke" : "Paint stroke")
            }
            if let last = lastPaintPoint {
                vm.labeling.paintStroke(
                    axis: axis,
                    sliceIndex: vm.sliceIndices[axis],
                    from: last, to: p, erase: erase,
                    recordUndo: false
                )
            } else {
                vm.labeling.paint(axis: axis, sliceIndex: vm.sliceIndices[axis],
                                  pixelX: p.0, pixelY: p.1, erase: erase,
                                  recordUndo: false)
            }
            lastPaintPoint = p

        case .regionGrow:
            // Single click -> region grow from seed
            if lastPaintPoint == nil {
                let (z, y, x) = vm.labeling.voxelCoordForClick(
                    axis: axis, sliceIndex: vm.sliceIndices[axis],
                    pixelX: p.0, pixelY: p.1
                )
                vm.startRegionGrowActiveLabelAroundSeed(
                    seed: (z: z, y: y, x: x),
                    tolerance: vm.labeling.regionGrowTolerance,
                    preferredVolume: volume
                )
                lastPaintPoint = p
            }

        case .threshold:
            // Single click -> percent-of-max around seed
            if lastPaintPoint == nil {
                let (z, y, x) = vm.labeling.voxelCoordForClick(
                    axis: axis, sliceIndex: vm.sliceIndices[axis],
                    pixelX: p.0, pixelY: p.1
                )
                vm.startPercentOfMaxActiveLabelAroundSeed(
                    seed: (z: z, y: y, x: x),
                    boxRadius: 30,
                    percent: vm.labeling.percentOfMax
                )
                lastPaintPoint = p
            }

        case .suvGradient:
            if lastPaintPoint == nil {
                let (z, y, x) = vm.labeling.voxelCoordForClick(
                    axis: axis, sliceIndex: vm.sliceIndices[axis],
                    pixelX: p.0, pixelY: p.1
                )
                vm.startGradientActiveLabelAroundSeed(
                    seed: (z: z, y: y, x: x),
                    minimumValue: vm.labeling.thresholdValue,
                    gradientCutoffFraction: vm.labeling.gradientCutoffFraction,
                    searchRadius: vm.labeling.gradientSearchRadius
                )
                lastPaintPoint = p
            }

        case .landmark:
            if lastPaintPoint == nil {
                let (z, y, x) = vm.labeling.voxelCoordForClick(
                    axis: axis, sliceIndex: vm.sliceIndices[axis],
                    pixelX: p.0, pixelY: p.1
                )
                let world = vm.labeling.crosshair.worldPoint(
                    from: (z: z, y: y, x: x), in: volume
                )
                vm.statusMessage = vm.labeling.captureLandmarkPoint(
                    SIMD3(world.x, world.y, world.z)
                )
                lastPaintPoint = p
            }

        default: break
        }
    }

    /// Convert a view point to image pixel coordinates (taking zoom/pan/flip into account).
    private func mapToImagePixel(point: CGPoint, volume: ImageVolume,
                                   geo: GeometryProxy) -> (Int, Int)? {
        // Image dimensions depend on axis
        let imgW: CGFloat
        let imgH: CGFloat
        switch axis {
        case 0: imgW = CGFloat(volume.height); imgH = CGFloat(volume.depth)
        case 1: imgW = CGFloat(volume.width);  imgH = CGFloat(volume.depth)
        default: imgW = CGFloat(volume.width); imgH = CGFloat(volume.height)
        }
        let fit = min(geo.size.width / imgW, geo.size.height / imgH) * zoom
        let displayW = imgW * fit
        let displayH = imgH * fit
        let originX = (geo.size.width - displayW) / 2 + pan.width
        let originY = (geo.size.height - displayH) / 2 + pan.height

        let localX = point.x - originX
        let localY = point.y - originY

        var px = Int((localX / fit).rounded(.down))
        var py = Int((localY / fit).rounded(.down))

        guard px >= 0, py >= 0, px < Int(imgW), py < Int(imgH) else { return nil }

        let transform = vm.displayTransform(for: axis, volume: volume)
        if transform.flipHorizontal {
            px = Int(imgW) - 1 - px
        }
        if transform.flipVertical {
            py = Int(imgH) - 1 - py
        }

        return (px, py)
    }

    // MARK: - Measurements

    private func isMeasurementTool(_ tool: ViewerTool) -> Bool {
        tool == .distance || tool == .angle || tool == .area
    }

    private func isTap(_ value: DragGesture.Value) -> Bool {
        abs(value.translation.width) < 4 && abs(value.translation.height) < 4
    }

    private func handleMeasurementTap(at location: CGPoint,
                                      volume: ImageVolume,
                                      geo: GeometryProxy) {
        guard let pixel = mapToImagePixel(point: location, volume: volume, geo: geo),
              let type = annotationType(for: vm.activeTool) else { return }

        measurementPoints.append(CGPoint(x: pixel.0, y: pixel.1))
        let required = Annotation(type: type, axis: axis,
                                  sliceIndex: vm.sliceIndices[axis]).minPointsRequired
        guard measurementPoints.count >= required else {
            vm.statusMessage = "\(type.rawValue.capitalized): \(measurementPoints.count)/\(required) points"
            return
        }

        var annotation = Annotation(type: type,
                                    points: measurementPoints,
                                    axis: axis,
                                    sliceIndex: vm.sliceIndices[axis])
        annotation.value = measurementValue(type: type,
                                            points: measurementPoints,
                                            volume: volume)
        annotation.unit = type == .angle ? "deg" : (type == .area ? "mm2" : "mm")
        vm.addAnnotation(annotation)
        vm.statusMessage = "Added \(annotation.displayText)"
        measurementPoints.removeAll()
    }

    private func annotationType(for tool: ViewerTool) -> AnnotationType? {
        switch tool {
        case .distance: return .distance
        case .angle:    return .angle
        case .area:     return .area
        default:        return nil
        }
    }

    private func measurementValue(type: AnnotationType,
                                  points: [CGPoint],
                                  volume: ImageVolume) -> Double {
        let worldPoints = points.map { worldPoint(for: $0, volume: volume) }
        switch type {
        case .distance:
            guard worldPoints.count >= 2 else { return 0 }
            return simd_length(worldPoints[1] - worldPoints[0])
        case .angle:
            guard worldPoints.count >= 3 else { return 0 }
            let a = worldPoints[0] - worldPoints[1]
            let b = worldPoints[2] - worldPoints[1]
            let denom = max(simd_length(a) * simd_length(b), 1e-12)
            let cosTheta = max(-1.0, min(1.0, simd_dot(a, b) / denom))
            return acos(cosTheta) * 180 / .pi
        case .area:
            guard worldPoints.count >= 3 else { return 0 }
            var crossSum = SIMD3<Double>(0, 0, 0)
            for i in 0..<worldPoints.count {
                crossSum += simd_cross(worldPoints[i], worldPoints[(i + 1) % worldPoints.count])
            }
            return 0.5 * simd_length(crossSum)
        default:
            return 0
        }
    }

    private func worldPoint(for point: CGPoint, volume: ImageVolume) -> SIMD3<Double> {
        let voxel: SIMD3<Double>
        switch axis {
        case 0:
            voxel = SIMD3<Double>(Double(vm.sliceIndices[axis]), Double(point.x), Double(point.y))
        case 1:
            voxel = SIMD3<Double>(Double(point.x), Double(vm.sliceIndices[axis]), Double(point.y))
        default:
            voxel = SIMD3<Double>(Double(point.x), Double(point.y), Double(vm.sliceIndices[axis]))
        }
        return volume.worldPoint(voxel: voxel)
    }

    // MARK: - Measurement canvas

    private func measurementCanvas(scale: CGFloat, imageSize: CGSize) -> some View {
        Canvas { context, size in
            // Draw existing measurements
            for ann in vm.annotations where ann.axis == axis && ann.sliceIndex == vm.sliceIndices[axis] {
                drawAnnotation(ann, in: context, scale: scale, imageSize: imageSize)
            }
        }
    }

    private struct CrossReferenceOverlayLine: Identifiable {
        let id: String
        let isVertical: Bool
        let position: CGFloat
        let color: Color
        let label: String
    }

    private func crossReferenceCanvas(scale: CGFloat, imageSize: CGSize) -> some View {
        Canvas { context, size in
            guard vm.labeling.crosshair.enabled else { return }
            let lines = crossReferenceLines(imageSize: imageSize)
            let style = StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [6, 4])

            for line in lines {
                let position = line.position * scale
                var path = Path()
                if line.isVertical {
                    path.move(to: CGPoint(x: position, y: 0))
                    path.addLine(to: CGPoint(x: position, y: size.height))
                } else {
                    path.move(to: CGPoint(x: 0, y: position))
                    path.addLine(to: CGPoint(x: size.width, y: position))
                }
                context.stroke(path, with: .color(line.color.opacity(0.78)), style: style)

                let labelPoint = line.isVertical
                    ? CGPoint(x: min(max(position + 18, 20), max(20, size.width - 24)), y: 14)
                    : CGPoint(x: 24, y: min(max(position - 10, 14), max(14, size.height - 14)))
                context.draw(
                    Text(line.label)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(line.color),
                    at: labelPoint
                )
            }
        }
        .allowsHitTesting(false)
    }

    private func crossReferenceLines(imageSize: CGSize) -> [CrossReferenceOverlayLine] {
        guard vm.volumeForDisplayMode(displayMode) != nil else { return [] }
        let width = max(1, Int(imageSize.width.rounded(.down)))
        let height = max(1, Int(imageSize.height.rounded(.down)))
        let transform = vm.displayTransform(for: axis, volume: vm.volumeForDisplayMode(displayMode))

        func clamped(_ value: Int, max upperBound: Int) -> Int {
            max(0, min(upperBound - 1, value))
        }

        func displayX(_ voxelIndex: Int) -> CGFloat {
            let raw = clamped(voxelIndex, max: width)
            let displayed = transform.flipHorizontal ? width - 1 - raw : raw
            return CGFloat(displayed) + 0.5
        }

        func displayY(_ voxelIndex: Int) -> CGFloat {
            let raw = clamped(voxelIndex, max: height)
            let displayed = transform.flipVertical ? height - 1 - raw : raw
            return CGFloat(displayed) + 0.5
        }

        func color(for planeAxis: Int) -> Color {
            switch planeAxis {
            case 0: return .cyan
            case 1: return .green
            default: return .orange
            }
        }

        func label(for planeAxis: Int) -> String {
            switch planeAxis {
            case 0: return "SAG"
            case 1: return "COR"
            default: return "AX"
            }
        }

        func vertical(axis planeAxis: Int, at index: Int) -> CrossReferenceOverlayLine {
            CrossReferenceOverlayLine(
                id: "v-\(planeAxis)",
                isVertical: true,
                position: displayX(index),
                color: color(for: planeAxis),
                label: label(for: planeAxis)
            )
        }

        func horizontal(axis planeAxis: Int, at index: Int) -> CrossReferenceOverlayLine {
            CrossReferenceOverlayLine(
                id: "h-\(planeAxis)",
                isVertical: false,
                position: displayY(index),
                color: color(for: planeAxis),
                label: label(for: planeAxis)
            )
        }

        switch axis {
        case 0:
            return [
                vertical(axis: 1, at: vm.sliceIndices[1]),
                horizontal(axis: 2, at: vm.sliceIndices[2])
            ]
        case 1:
            return [
                vertical(axis: 0, at: vm.sliceIndices[0]),
                horizontal(axis: 2, at: vm.sliceIndices[2])
            ]
        default:
            return [
                vertical(axis: 0, at: vm.sliceIndices[0]),
                horizontal(axis: 1, at: vm.sliceIndices[1])
            ]
        }
    }

    private func drawAnnotation(_ ann: Annotation, in context: GraphicsContext,
                                 scale: CGFloat, imageSize: CGSize) {
        let points = ann.points
            .map { displayPoint(for: $0, imageSize: imageSize) }
            .map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
        let strokeColor = Color.yellow

        switch ann.type {
        case .distance:
            if points.count >= 2 {
                var path = Path()
                path.move(to: points[0])
                path.addLine(to: points[1])
                context.stroke(path, with: .color(strokeColor), lineWidth: 1.5)
                drawText(ann.displayText,
                         at: CGPoint(x: (points[0].x + points[1].x) / 2,
                                     y: (points[0].y + points[1].y) / 2),
                         in: context)
            }
        case .angle:
            if points.count >= 3 {
                var path = Path()
                path.move(to: points[0])
                path.addLine(to: points[1])
                path.addLine(to: points[2])
                context.stroke(path, with: .color(strokeColor), lineWidth: 1.5)
                drawText(ann.displayText, at: points[1], in: context)
            }
        case .area:
            if points.count >= 3 {
                var path = Path()
                path.move(to: points[0])
                for p in points.dropFirst() { path.addLine(to: p) }
                path.closeSubpath()
                context.fill(path, with: .color(.yellow.opacity(0.2)))
                context.stroke(path, with: .color(strokeColor), lineWidth: 1.5)
                let cx = points.reduce(0.0) { $0 + $1.x } / CGFloat(points.count)
                let cy = points.reduce(0.0) { $0 + $1.y } / CGFloat(points.count)
                drawText(ann.displayText, at: CGPoint(x: cx, y: cy), in: context)
            }
        default:
            break
        }

        // Draw dots at each point
        for p in points {
            let r: CGFloat = 3
            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            context.fill(Path(ellipseIn: rect), with: .color(.yellow))
        }
    }

    private func drawText(_ text: String, at point: CGPoint, in context: GraphicsContext) {
        let t = Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(.yellow)
        context.draw(t, at: CGPoint(x: point.x + 4, y: point.y - 8))
    }

    private func displayPoint(for point: CGPoint, imageSize: CGSize) -> CGPoint {
        let transform = vm.displayTransform(for: axis, volume: vm.volumeForDisplayMode(displayMode))
        var display = point
        if transform.flipHorizontal {
            display.x = imageSize.width - 1 - display.x
        }
        if transform.flipVertical {
            display.y = imageSize.height - 1 - display.y
        }
        return display
    }

    // MARK: - Reset

    private func resetView() {
        vm.resetViewportTransform(for: viewportKey)
    }
}

#if os(macOS)
private struct SliceScrollWheelEvent {
    let rawDeltaY: CGFloat
    let hasPreciseScrollingDeltas: Bool
    let modifierFlags: NSEvent.ModifierFlags

    init(_ event: NSEvent) {
        self.rawDeltaY = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
        self.hasPreciseScrollingDeltas = event.hasPreciseScrollingDeltas
        self.modifierFlags = event.modifierFlags
    }
}

private struct SliceScrollWheelBridge: NSViewRepresentable {
    var onScroll: (SliceScrollWheelEvent) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScroll: onScroll)
    }

    func makeNSView(context: Context) -> ScrollWheelView {
        let view = ScrollWheelView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: ScrollWheelView, context: Context) {
        context.coordinator.onScroll = onScroll
        nsView.coordinator = context.coordinator
    }

    static func dismantleNSView(_ nsView: ScrollWheelView, coordinator: Coordinator) {
        nsView.removeMonitor()
    }

    final class Coordinator {
        var onScroll: (SliceScrollWheelEvent) -> Void

        init(onScroll: @escaping (SliceScrollWheelEvent) -> Void) {
            self.onScroll = onScroll
        }
    }

    final class ScrollWheelView: NSView {
        weak var coordinator: Coordinator?
        private var monitor: Any?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            installMonitor()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            installMonitor()
        }

        deinit {
            removeMonitor()
        }

        private func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self,
                      let window = self.window,
                      event.window === window else {
                    return event
                }
                let point = convert(event.locationInWindow, from: nil)
                guard bounds.contains(point) else { return event }
                let capturedEvent = SliceScrollWheelEvent(event)
                DispatchQueue.main.async { [weak self] in
                    self?.coordinator?.onScroll(capturedEvent)
                }
                return nil
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
#endif
