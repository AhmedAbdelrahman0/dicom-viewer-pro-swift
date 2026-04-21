import SwiftUI

#if canImport(MetalKit)
import MetalKit
import simd
#endif

struct VolumeRenderingPane: View {
    @EnvironmentObject var vm: ViewerViewModel
    @State private var mode: VolumeRenderMode = .mip
    @State private var opacity: Double = 0.18
    @State private var density: Double = 1.15
    @State private var sampleCount: Double = 288
    @State private var rotation = CGSize(width: 28, height: -18)
    @State private var lastRotation = CGSize(width: 28, height: -18)
    @State private var zoom: Double = 1.25
    @State private var lastZoom: Double = 1.25

    var body: some View {
        VStack(spacing: 0) {
            header

            ZStack {
                Color.black

                if let volume = vm.currentVolume {
                    #if canImport(MetalKit)
                    MetalVolumeView(
                        volume: volume,
                        settings: VolumeRenderSettings(
                            window: Float(vm.window),
                            level: Float(vm.level),
                            opacity: Float(opacity),
                            density: Float(density),
                            sampleCount: UInt32(sampleCount),
                            rotationX: Float(rotation.height * .pi / 180),
                            rotationY: Float(rotation.width * .pi / 180),
                            zoom: Float(zoom),
                            mode: mode,
                            invert: vm.invertColors
                        )
                    )
                    .gesture(rotationGesture)
                    .simultaneousGesture(zoomGesture)
                    .overlay(alignment: .bottomLeading) {
                        renderControls
                    }
                    #else
                    Text("Metal is not available on this platform")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    #endif
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "cube.transparent")
                            .font(.system(size: 34))
                            .foregroundColor(.secondary)
                        Text("Load a volume to render")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .background(Color(.displayP3, white: 0.08))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("3D GPU")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.blue)
            if let v = vm.currentVolume {
                Text("\(v.width)x\(v.height)x\(v.depth)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Picker("", selection: $mode) {
                ForEach(VolumeRenderMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .controlSize(.small)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.displayP3, white: 0.1))
    }

    private var renderControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("\(Int(sampleCount))", systemImage: "line.3.horizontal.decrease")
                    .font(.system(size: 10, design: .monospaced))
                Slider(value: $sampleCount, in: 96...640, step: 32)
                    .frame(width: 120)
            }

            if mode == .composite {
                HStack(spacing: 8) {
                    Label("\(Int(opacity * 100))%", systemImage: "circle.lefthalf.filled")
                        .font(.system(size: 10, design: .monospaced))
                    Slider(value: $opacity, in: 0.04...0.55)
                        .frame(width: 120)
                }

                HStack(spacing: 8) {
                    Label(String(format: "%.1fx", density), systemImage: "dial.medium")
                        .font(.system(size: 10, design: .monospaced))
                    Slider(value: $density, in: 0.5...4.0)
                        .frame(width: 120)
                }
            }

            HStack(spacing: 8) {
                Button {
                    rotation = CGSize(width: 28, height: -18)
                    lastRotation = rotation
                    zoom = 1.25
                    lastZoom = zoom
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Text(String(format: "%.1fx", zoom))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(8)
    }

    private var rotationGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                rotation = CGSize(
                    width: lastRotation.width + value.translation.width * 0.35,
                    height: max(-85, min(85, lastRotation.height + value.translation.height * 0.35))
                )
            }
            .onEnded { _ in
                lastRotation = rotation
            }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                zoom = max(0.45, min(3.5, lastZoom * Double(value)))
            }
            .onEnded { _ in
                lastZoom = zoom
            }
    }
}

enum VolumeRenderMode: UInt32, CaseIterable, Identifiable {
    case mip = 0
    case composite = 1

    var id: UInt32 { rawValue }

    var displayName: String {
        switch self {
        case .mip: return "MIP"
        case .composite: return "VR"
        }
    }
}

struct VolumeRenderSettings: Equatable {
    var window: Float
    var level: Float
    var opacity: Float
    var density: Float
    var sampleCount: UInt32
    var rotationX: Float
    var rotationY: Float
    var zoom: Float
    var mode: VolumeRenderMode
    var invert: Bool
}

#if os(macOS) && canImport(MetalKit)
struct MetalVolumeView: NSViewRepresentable {
    let volume: ImageVolume
    let settings: VolumeRenderSettings

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        context.coordinator.makeView()
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.renderer.update(volume: volume, settings: settings)
        view.draw()
    }

    final class Coordinator {
        let renderer = MetalVolumeRenderer()

        func makeView() -> MTKView {
            let view = MTKView(frame: .zero, device: renderer.device)
            view.delegate = renderer
            view.colorPixelFormat = .bgra8Unorm
            view.depthStencilPixelFormat = .invalid
            view.framebufferOnly = true
            view.isPaused = true
            view.enableSetNeedsDisplay = true
            view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            return view
        }
    }
}
#elseif os(iOS) && canImport(MetalKit)
struct MetalVolumeView: UIViewRepresentable {
    let volume: ImageVolume
    let settings: VolumeRenderSettings

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        context.coordinator.makeView()
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.renderer.update(volume: volume, settings: settings)
        view.draw()
    }

    final class Coordinator {
        let renderer = MetalVolumeRenderer()

        func makeView() -> MTKView {
            let view = MTKView(frame: .zero, device: renderer.device)
            view.delegate = renderer
            view.colorPixelFormat = .bgra8Unorm
            view.depthStencilPixelFormat = .invalid
            view.framebufferOnly = true
            view.isPaused = true
            view.enableSetNeedsDisplay = true
            view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            return view
        }
    }
}
#endif
