import Foundation
import SwiftUI

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
        // LPS with identity direction:
        //   world.x = origin.x + x * spacing.x
        //   world.y = origin.y + y * spacing.y
        //   world.z = origin.z + z * spacing.z
        WorldPoint(
            x: volume.origin.x + Double(voxel.x) * volume.spacing.x,
            y: volume.origin.y + Double(voxel.y) * volume.spacing.y,
            z: volume.origin.z + Double(voxel.z) * volume.spacing.z
        )
    }

    /// Convert world LPS coordinates to voxel indices for a volume.
    public func voxel(from world: WorldPoint,
                      in volume: ImageVolume) -> (z: Int, y: Int, x: Int) {
        let x = Int(round((world.x - volume.origin.x) / volume.spacing.x))
        let y = Int(round((world.y - volume.origin.y) / volume.spacing.y))
        let z = Int(round((world.z - volume.origin.z) / volume.spacing.z))
        return (clamp(z, 0, volume.depth - 1),
                clamp(y, 0, volume.height - 1),
                clamp(x, 0, volume.width - 1))
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
