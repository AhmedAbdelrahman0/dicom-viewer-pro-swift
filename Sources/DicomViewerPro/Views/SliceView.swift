import SwiftUI
import CoreGraphics
import simd

/// A single 2D slice view (axial, sagittal, or coronal) with full tool support.
public struct SliceView: View {
    @EnvironmentObject var vm: ViewerViewModel
    let axis: Int
    let title: String

    // Per-view display transform state
    @State private var zoom: CGFloat = 1.0
    @State private var pan: CGSize = .zero
    @State private var measurementPoints: [CGPoint] = []
    @State private var activeMeasurement: Annotation?
    @State private var dragStart: CGPoint?
    @State private var lastPaintPoint: (Int, Int)?

    public init(axis: Int, title: String) {
        self.axis = axis
        self.title = title
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geo in
                ZStack {
                    Color.black

                    if let cg = vm.makeImage(for: axis) {
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
                        if let ov = vm.makeOverlayImage(for: axis) {
                            Image(decorative: ov, scale: 1.0)
                                .resizable()
                                .interpolation(.medium)
                                .frame(width: imgW * fit, height: imgH * fit)
                                .offset(pan)
                        }

                        // Label overlay
                        if let lbl = vm.makeLabelImage(for: axis) {
                            Image(decorative: lbl, scale: 1.0)
                                .resizable()
                                .interpolation(.none)
                                .frame(width: imgW * fit, height: imgH * fit)
                                .offset(pan)
                        }

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

                    // Info label (top-left)
                    VStack {
                        HStack {
                            infoText
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(6)
                }
                .clipped()
                .contentShape(Rectangle())
                .gesture(scrollGesture(geo: geo))
                .gesture(dragGesture(geo: geo))
                .onTapGesture(count: 2) { resetView() }
                .onContinuousHover { phase in
                    // Scroll wheel (on macOS) could be connected here via a different
                    // mechanism; we use onScroll elsewhere.
                }
                #if os(macOS)
                .onAppear { NSCursor.setHiddenUntilMouseMoves(false) }
                #endif
            }
            .background(Color.black)
            .overlay(
                Rectangle()
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )
        }
        .background(Color(.displayP3, white: 0.08))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.blue)
                .help("\(title) view\nScroll wheel or slider to navigate slices")

            Spacer()

            HoverIconButton(
                systemImage: "circle.righthalf.filled",
                tooltip: "Invert Colors (all views)\n"
                       + "Toggles grayscale inversion — useful for reading MRI\n"
                       + "or X-ray images in the radiological convention.",
                isActive: vm.invertColors
            ) {
                vm.invertColors.toggle()
            }

            HoverIconButton(
                systemImage: "rectangle.on.rectangle.angled",
                tooltip: "Reset view (zoom + pan)\nDouble-click the view also resets."
            ) {
                zoom = 1.0; pan = .zero
            }

            sliceScrubber
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.displayP3, white: 0.1))
    }

    private var sliceScrubber: some View {
        HStack(spacing: 4) {
            if let v = vm.currentVolume {
                let maxIdx: Int = {
                    switch axis {
                    case 0: return v.width - 1
                    case 1: return v.height - 1
                    default: return v.depth - 1
                    }
                }()
                let binding = Binding<Double>(
                    get: { Double(vm.sliceIndices[axis]) },
                    set: { vm.setSlice(axis: axis, index: Int($0)) }
                )
                Text("\(vm.sliceIndices[axis] + 1)/\(maxIdx + 1)")
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
            if let v = vm.currentVolume {
                let (w, h) = sliceDimensions(for: v)
                Text("\(w)×\(h)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray)
                Text("W: \(Int(vm.window))  L: \(Int(vm.level))")
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

    private func sliceDimensions(for v: ImageVolume) -> (Int, Int) {
        switch axis {
        case 0: return (v.height, v.depth)
        case 1: return (v.width, v.depth)
        default: return (v.width, v.height)
        }
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
        guard let volume = vm.currentVolume else {
            return fallbackOrientationLetters(for: axis)
        }

        let rightVector: SIMD3<Double>
        let downVector: SIMD3<Double>
        switch axis {
        case 0:
            rightVector = volume.direction[1]
            downVector = -volume.direction[2]
        case 1:
            rightVector = volume.direction[0]
            downVector = -volume.direction[2]
        default:
            rightVector = volume.direction[0]
            downVector = volume.direction[1]
        }

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
        let absX = abs(vector.x)
        let absY = abs(vector.y)
        let absZ = abs(vector.z)
        if absX >= absY && absX >= absZ {
            return vector.x >= 0 ? "L" : "R"
        }
        if absY >= absX && absY >= absZ {
            return vector.y >= 0 ? "P" : "A"
        }
        return vector.z >= 0 ? "H" : "F"
    }

    // MARK: - Gestures

    private func scrollGesture(geo: GeometryProxy) -> some Gesture {
        // Magnification for pinch-to-zoom
        MagnificationGesture()
            .onChanged { scale in
                zoom = max(0.25, min(10.0, scale))
            }
    }

    private func dragGesture(geo: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let translation = value.translation
                if dragStart == nil { dragStart = value.location }

                // Labeling tools take priority over viewer tools
                if vm.labeling.labelingTool != .none,
                   let v = vm.currentVolume {
                    handleLabelingDrag(value: value, volume: v, geo: geo)
                    return
                }

                switch vm.activeTool {
                case .wl:
                    if let start = dragStart {
                        let dx = value.location.x - start.x
                        let dy = value.location.y - start.y
                        dragStart = value.location
                        vm.adjustWindowLevel(dw: Double(dx) * 2, dl: -Double(dy) * 2)
                    }
                case .pan:
                    pan = translation
                case .zoom:
                    let factor = 1.0 + Double(-translation.height) * 0.005
                    zoom = CGFloat(max(0.25, min(10.0, Double(zoom) * factor)))
                case .distance, .angle, .area:
                    break
                }
            }
            .onEnded { value in
                if vm.labeling.labelingTool != .none {
                    vm.labeling.commitVoxelEdit()
                }
                if vm.labeling.labelingTool == .none,
                   isMeasurementTool(vm.activeTool),
                   isTap(value),
                   let volume = vm.currentVolume {
                    handleMeasurementTap(at: value.location, volume: volume, geo: geo)
                }
                dragStart = nil
                lastPaintPoint = nil
            }
    }

    private func handleLabelingDrag(value: DragGesture.Value, volume: ImageVolume,
                                     geo: GeometryProxy) {
        let pixel = mapToImagePixel(point: value.location, volume: volume, geo: geo)
        guard let p = pixel else { return }

        switch vm.labeling.labelingTool {
        case .brush, .eraser:
            let erase = vm.labeling.labelingTool == .eraser
            if lastPaintPoint == nil {
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
                vm.labeling.regionGrow(
                    volume: volume,
                    seed: (z: z, y: y, x: x),
                    tolerance: vm.labeling.regionGrowTolerance
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
                vm.percentOfMaxActiveLabelAroundSeed(
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
                vm.gradientActiveLabelAroundSeed(
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

        let px = Int(localX / fit)
        var py = Int(localY / fit)

        // Account for vertical flip used on sagittal/coronal
        if axis == 0 || axis == 1 {
            py = Int(imgH) - 1 - py
        }

        guard px >= 0, py >= 0, px < Int(imgW), py < Int(imgH) else { return nil }
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
        vm.annotations.append(annotation)
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
        guard axis == 0 || axis == 1 else { return point }
        return CGPoint(x: point.x, y: imageSize.height - 1 - point.y)
    }

    // MARK: - Reset

    private func resetView() {
        zoom = 1.0
        pan = .zero
    }
}
