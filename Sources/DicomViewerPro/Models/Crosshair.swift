import Foundation
import SwiftUI
import simd

/// World-space position (LPS mm) used to synchronize MPR views and fused volumes.
public struct WorldPoint: Equatable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double = 0, y: Double = 0, z: Double = 0) {
        self.x = x; self.y = y; self.z = z
    }
}

/// Manages the crosshair position in world coordinates and converts between
/// voxel/world coordinates for each loaded volume.
@MainActor
public final class CrosshairSync: ObservableObject {
    @Published public var world: WorldPoint = WorldPoint()
    @Published public var enabled: Bool = true
    @Published public var color: Color = .green
    @Published public var showOnlyOnHover: Bool = false

    public init() {}

    /// Convert voxel index (z, y, x) in a volume to world LPS coordinates.
    public func worldPoint(from voxel: (z: Int, y: Int, x: Int),
                           in volume: ImageVolume) -> WorldPoint {
        let p = volume.worldPoint(z: voxel.z, y: voxel.y, x: voxel.x)
        return WorldPoint(x: p.x, y: p.y, z: p.z)
    }

    public func worldPoint(from voxel: SIMD3<Double>,
                           in volume: ImageVolume) -> WorldPoint {
        let p = volume.worldPoint(voxel: voxel)
        return WorldPoint(
            x: p.x,
            y: p.y,
            z: p.z
        )
    }

    /// Convert world LPS coordinates to voxel indices for a volume.
    public func voxel(from world: WorldPoint,
                      in volume: ImageVolume) -> (z: Int, y: Int, x: Int) {
        volume.voxelIndex(from: SIMD3<Double>(world.x, world.y, world.z))
    }

    /// The slice index on each axis for a given world point in a volume.
    public func sliceIndices(for world: WorldPoint,
                             in volume: ImageVolume) -> (sag: Int, cor: Int, ax: Int) {
        let v = voxel(from: world, in: volume)
        return (sag: v.x, cor: v.y, ax: v.z)  // axis 0 = x-index (sagittal)
    }

    /// Update from a 2D pixel click in one MPR view.
    public func updateFromClick(axis: Int,
                                 pixelX: Int,
                                 pixelY: Int,
                                 sliceIndex: Int,
                                 volume: ImageVolume) {
        // Convert the pixel click in the displayed slice back to voxel (z,y,x)
        let vox: (z: Int, y: Int, x: Int)
        switch axis {
        case 0:
            // Sagittal: displayed as (Z, Y) but may be flipped for display.
            // The caller passes pixel coords in the *oriented* image, so we
            // assume they have already inverted the Y display flip.
            vox = (z: pixelY, y: pixelX, x: sliceIndex)
        case 1:
            // Coronal
            vox = (z: pixelY, y: sliceIndex, x: pixelX)
        default:
            // Axial
            vox = (z: sliceIndex, y: pixelY, x: pixelX)
        }
        self.world = worldPoint(from: vox, in: volume)
    }

    private func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
        max(lo, min(hi, v))
    }
}
