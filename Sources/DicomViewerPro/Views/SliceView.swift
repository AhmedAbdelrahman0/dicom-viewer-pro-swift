import SwiftUI
import CoreGraphics

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

                        // Measurements overlay
                        measurementCanvas(scale: fit, imageSize: CGSize(width: imgW, height: imgH))
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
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.blue)

            Spacer()

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
        switch axis {
        case 0: return ("H", "F", "A", "P")   // Sagittal
        case 1: return ("H", "F", "R", "L")   // Coronal
        default: return ("A", "P", "R", "L")  // Axial
        }
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
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let translation = value.translation
                if dragStart == nil { dragStart = value.location }

                switch vm.activeTool {
                case .wl:
                    // Apply incrementally using delta from last mouse position
                    if let start = dragStart {
                        let dx = value.location.x - start.x
                        let dy = value.location.y - start.y
                        dragStart = value.location
                        vm.adjustWindowLevel(dw: Double(dx) * 2, dl: -Double(dy) * 2)
                    }
                case .pan:
                    pan = translation
                case .zoom:
                    // Drag up zooms in, drag down zooms out
                    let factor = 1.0 + Double(-translation.height) * 0.005
                    zoom = CGFloat(max(0.25, min(10.0, Double(zoom) * factor)))
                case .distance, .angle, .area:
                    break  // handled on tap
                }
            }
            .onEnded { _ in
                dragStart = nil
            }
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
        let points = ann.points.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
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

    // MARK: - Reset

    private func resetView() {
        zoom = 1.0
        pan = .zero
    }
}
