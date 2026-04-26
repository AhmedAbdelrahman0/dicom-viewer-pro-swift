import Foundation

#if canImport(MetalKit)
import MetalKit
import simd

final class MetalVolumeRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice?

    private let commandQueue: MTLCommandQueue?
    private let pipelineState: MTLRenderPipelineState?
    private let samplerState: MTLSamplerState?
    private var volumeTexture: MTLTexture?
    private var volumeID: UUID?
    private var volumeExtent = SIMD3<Float>(1, 1, 1)
    private var settings = VolumeRenderSettings(
        window: 400,
        level: 40,
        opacity: 0.18,
        density: 1.15,
        sampleCount: 288,
        maxTextureDimension: 384,
        rotationX: -0.31,
        rotationY: 0.49,
        zoom: 1.25,
        mode: .mip,
        invert: false
    )

    var isReady: Bool {
        pipelineState != nil && samplerState != nil
    }

    override init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            self.device = nil
            self.commandQueue = nil
            self.pipelineState = nil
            self.samplerState = nil
            super.init()
            return
        }

        self.device = device
        self.commandQueue = commandQueue

        let library = try? device.makeLibrary(source: Self.shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library?.makeFunction(name: "volumeVertex")
        descriptor.fragmentFunction = library?.makeFunction(name: "volumeFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.pipelineState = try? device.makeRenderPipelineState(descriptor: descriptor)

        let sampler = MTLSamplerDescriptor()
        sampler.minFilter = .linear
        sampler.magFilter = .linear
        sampler.mipFilter = .notMipmapped
        sampler.sAddressMode = .clampToEdge
        sampler.tAddressMode = .clampToEdge
        sampler.rAddressMode = .clampToEdge
        self.samplerState = device.makeSamplerState(descriptor: sampler)

        super.init()
    }

    func update(volume: ImageVolume, settings: VolumeRenderSettings) {
        self.settings = settings
        guard let device else { return }
        guard volumeID != volume.id else { return }

        let payload = VolumeTexturePayload.make(
            from: volume,
            maxDimension: Int(settings.maxTextureDimension)
        )
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r32Float
        descriptor.width = payload.width
        descriptor.height = payload.height
        descriptor.depth = payload.depth
        descriptor.mipmapLevelCount = 1
        descriptor.usage = MTLTextureUsage.shaderRead
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else { return }
        payload.pixels.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake3D(0, 0, 0, payload.width, payload.height, payload.depth),
                mipmapLevel: 0,
                slice: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: payload.width * MemoryLayout<Float>.stride,
                bytesPerImage: payload.width * payload.height * MemoryLayout<Float>.stride
            )
        }

        volumeTexture = texture
        volumeID = volume.id
        volumeExtent = payload.extent
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandQueue,
              let pipelineState,
              let samplerState,
              let volumeTexture,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        var uniforms = makeUniforms(drawableSize: view.drawableSize)
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(volumeTexture, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VolumeUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func makeUniforms(drawableSize: CGSize) -> VolumeUniforms {
        let aspect = Float(max(drawableSize.width, 1) / max(drawableSize.height, 1))
        let cameraDistance = max(1.15, 2.55 / max(settings.zoom, 0.1))
        let projection = simd_float4x4.perspective(
            fovyRadians: 45 * .pi / 180,
            aspect: aspect,
            near: 0.05,
            far: 10
        )
        let eye = SIMD3<Float>(0, 0, cameraDistance)
        let view = simd_float4x4.lookAt(
            eye: eye,
            center: SIMD3<Float>(0, 0, 0),
            up: SIMD3<Float>(0, 1, 0)
        )
        let model = simd_float4x4.rotation(radians: settings.rotationY, axis: SIMD3<Float>(0, 1, 0))
            * simd_float4x4.rotation(radians: settings.rotationX, axis: SIMD3<Float>(1, 0, 0))

        let minValue = settings.level - settings.window * 0.5
        let inverseWindow = 1 / max(settings.window, 0.001)

        return VolumeUniforms(
            inverseViewProjection: simd_inverse(projection * view),
            inverseModelMatrix: simd_inverse(model),
            cameraPositionWorld: SIMD4<Float>(eye.x, eye.y, eye.z, 1),
            volumeExtent: SIMD4<Float>(volumeExtent.x, volumeExtent.y, volumeExtent.z, 0),
            transfer: SIMD4<Float>(minValue, inverseWindow, settings.opacity, settings.density),
            options: SIMD4<UInt32>(
                settings.mode.rawValue,
                settings.invert ? 1 : 0,
                max(32, min(settings.sampleCount, 768)),
                0
            )
        )
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 ndc;
    };

    struct VolumeUniforms {
        float4x4 inverseViewProjection;
        float4x4 inverseModelMatrix;
        float4 cameraPositionWorld;
        float4 volumeExtent;
        float4 transfer;
        uint4 options;
    };

    vertex VertexOut volumeVertex(uint vertexID [[vertex_id]]) {
        constexpr float2 positions[6] = {
            float2(-1.0, -1.0), float2( 1.0, -1.0), float2(-1.0,  1.0),
            float2( 1.0, -1.0), float2( 1.0,  1.0), float2(-1.0,  1.0)
        };

        VertexOut out;
        out.position = float4(positions[vertexID], 0.0, 1.0);
        out.ndc = positions[vertexID];
        return out;
    }

    static bool intersectBox(float3 rayOrigin,
                             float3 rayDirection,
                             float3 boxMin,
                             float3 boxMax,
                             thread float &tNear,
                             thread float &tFar) {
        float3 invDirection = 1.0 / rayDirection;
        float3 t0 = (boxMin - rayOrigin) * invDirection;
        float3 t1 = (boxMax - rayOrigin) * invDirection;
        float3 smaller = min(t0, t1);
        float3 larger = max(t0, t1);
        tNear = max(max(smaller.x, smaller.y), smaller.z);
        tFar = min(min(larger.x, larger.y), larger.z);
        return tFar >= max(tNear, 0.0);
    }

    static float normalizedIntensity(float rawValue, constant VolumeUniforms &uniforms) {
        return clamp((rawValue - uniforms.transfer.x) * uniforms.transfer.y, 0.0, 1.0);
    }

    static float3 shade(float value, constant VolumeUniforms &uniforms) {
        float v = uniforms.options.y == 1 ? 1.0 - value : value;
        return float3(v);
    }

    fragment float4 volumeFragment(VertexOut in [[stage_in]],
                                   texture3d<float, access::sample> volume [[texture(0)]],
                                   sampler volumeSampler [[sampler(0)]],
                                   constant VolumeUniforms &uniforms [[buffer(0)]]) {
        float4 nearClip = uniforms.inverseViewProjection * float4(in.ndc, 0.0, 1.0);
        float4 farClip = uniforms.inverseViewProjection * float4(in.ndc, 1.0, 1.0);
        float3 nearWorld = nearClip.xyz / nearClip.w;
        float3 farWorld = farClip.xyz / farClip.w;

        float3 cameraWorld = uniforms.cameraPositionWorld.xyz;
        float3 rayWorld = normalize(farWorld - cameraWorld);
        float3 rayOrigin = (uniforms.inverseModelMatrix * float4(cameraWorld, 1.0)).xyz;
        float3 rayDirection = normalize((uniforms.inverseModelMatrix * float4(rayWorld, 0.0)).xyz);

        float3 halfExtent = max(uniforms.volumeExtent.xyz * 0.5, float3(0.001));
        float tNear = 0.0;
        float tFar = 0.0;
        if (!intersectBox(rayOrigin, rayDirection, -halfExtent, halfExtent, tNear, tFar)) {
            return float4(0.0, 0.0, 0.0, 1.0);
        }

        tNear = max(tNear, 0.0);
        uint sampleCount = clamp(uniforms.options.z, 32u, 768u);
        float stepLength = (tFar - tNear) / float(sampleCount);
        if (stepLength <= 0.0) {
            return float4(0.0, 0.0, 0.0, 1.0);
        }

        float maxValue = 0.0;
        float4 accumulated = float4(0.0);
        float t = tNear;

        for (uint i = 0; i < 768; ++i) {
            if (i >= sampleCount) { break; }

            float3 position = rayOrigin + rayDirection * t;
            float3 texCoord = position / (halfExtent * 2.0) + 0.5;
            float rawValue = volume.sample(volumeSampler, texCoord).r;
            float value = normalizedIntensity(rawValue, uniforms);

            if (uniforms.options.x == 0) {
                maxValue = max(maxValue, value);
            } else {
                float alpha = pow(value, 1.35) * uniforms.transfer.z * uniforms.transfer.w;
                alpha = clamp(alpha * 4.0 / float(sampleCount), 0.0, 0.35);
                float3 color = shade(value, uniforms);
                accumulated.rgb += (1.0 - accumulated.a) * color * alpha;
                accumulated.a += (1.0 - accumulated.a) * alpha;
                if (accumulated.a > 0.96) { break; }
            }

            t += stepLength;
        }

        if (uniforms.options.x == 0) {
            return float4(shade(maxValue, uniforms), 1.0);
        }

        float3 color = accumulated.rgb + float3(0.015, 0.018, 0.022) * (1.0 - accumulated.a);
        return float4(color, 1.0);
    }
    """
}

struct VolumeTexturePayload {
    let pixels: [Float]
    let width: Int
    let height: Int
    let depth: Int
    let extent: SIMD3<Float>

    static func make(from volume: ImageVolume, maxDimension: Int) -> VolumeTexturePayload {
        let longest = max(volume.width, max(volume.height, volume.depth))
        let scale = longest > maxDimension ? Double(maxDimension) / Double(longest) : 1
        let width = max(1, Int((Double(volume.width) * scale).rounded()))
        let height = max(1, Int((Double(volume.height) * scale).rounded()))
        let depth = max(1, Int((Double(volume.depth) * scale).rounded()))

        let pixels: [Float]
        if width == volume.width, height == volume.height, depth == volume.depth {
            pixels = volume.pixels
        } else {
            pixels = downsample(volume: volume, width: width, height: height, depth: depth)
        }

        let physicalWidth = Float(Double(volume.width) * volume.spacing.x)
        let physicalHeight = Float(Double(volume.height) * volume.spacing.y)
        let physicalDepth = Float(Double(volume.depth) * volume.spacing.z)
        let maxPhysical = max(physicalWidth, max(physicalHeight, physicalDepth))
        let extent = SIMD3<Float>(
            physicalWidth / max(maxPhysical, 0.001),
            physicalHeight / max(maxPhysical, 0.001),
            physicalDepth / max(maxPhysical, 0.001)
        )

        return VolumeTexturePayload(
            pixels: pixels,
            width: width,
            height: height,
            depth: depth,
            extent: extent
        )
    }

    private static func downsample(volume: ImageVolume,
                                   width: Int,
                                   height: Int,
                                   depth: Int) -> [Float] {
        var out = [Float](repeating: 0, count: width * height * depth)

        let sx = Double(volume.width - 1) / Double(max(width - 1, 1))
        let sy = Double(volume.height - 1) / Double(max(height - 1, 1))
        let sz = Double(volume.depth - 1) / Double(max(depth - 1, 1))

        for z in 0..<depth {
            let srcZ = min(volume.depth - 1, max(0, Int((Double(z) * sz).rounded())))
            for y in 0..<height {
                let srcY = min(volume.height - 1, max(0, Int((Double(y) * sy).rounded())))
                let srcRow = srcZ * volume.height * volume.width + srcY * volume.width
                let dstRow = z * height * width + y * width
                for x in 0..<width {
                    let srcX = min(volume.width - 1, max(0, Int((Double(x) * sx).rounded())))
                    out[dstRow + x] = volume.pixels[srcRow + srcX]
                }
            }
        }

        return out
    }
}

private struct VolumeUniforms {
    var inverseViewProjection: simd_float4x4
    var inverseModelMatrix: simd_float4x4
    var cameraPositionWorld: SIMD4<Float>
    var volumeExtent: SIMD4<Float>
    var transfer: SIMD4<Float>
    var options: SIMD4<UInt32>
}

private extension simd_float4x4 {
    static func perspective(fovyRadians: Float,
                            aspect: Float,
                            near: Float,
                            far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovyRadians * 0.5)
        let x = y / aspect
        let z = far / (near - far)

        return simd_float4x4(columns: (
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, z * near, 0)
        ))
    }

    static func lookAt(eye: SIMD3<Float>,
                       center: SIMD3<Float>,
                       up: SIMD3<Float>) -> simd_float4x4 {
        let forward = simd_normalize(center - eye)
        let side = simd_normalize(simd_cross(forward, up))
        let upVector = simd_cross(side, forward)

        return simd_float4x4(columns: (
            SIMD4<Float>(side.x, upVector.x, -forward.x, 0),
            SIMD4<Float>(side.y, upVector.y, -forward.y, 0),
            SIMD4<Float>(side.z, upVector.z, -forward.z, 0),
            SIMD4<Float>(-simd_dot(side, eye), -simd_dot(upVector, eye), simd_dot(forward, eye), 1)
        ))
    }

    static func rotation(radians: Float, axis: SIMD3<Float>) -> simd_float4x4 {
        let axis = simd_normalize(axis)
        let c = cos(radians)
        let s = sin(radians)
        let t = 1 - c
        let x = axis.x
        let y = axis.y
        let z = axis.z

        return simd_float4x4(columns: (
            SIMD4<Float>(t * x * x + c, t * x * y + s * z, t * x * z - s * y, 0),
            SIMD4<Float>(t * x * y - s * z, t * y * y + c, t * y * z + s * x, 0),
            SIMD4<Float>(t * x * z + s * y, t * y * z - s * x, t * z * z + c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }
}
#endif
