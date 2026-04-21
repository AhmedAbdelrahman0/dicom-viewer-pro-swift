import Foundation
import simd

/// Resampling of label maps between different volume grids through a
/// registration transform. Uses **nearest-neighbor interpolation** to avoid
/// mixing class IDs.
public enum LabelMigration {

    /// Resample a `source` label map (defined in `sourceVolume`'s grid) into
    /// a new label map aligned with `targetVolume`'s grid. A rigid/affine
    /// `transform` maps target world coordinates to source world coordinates.
    public static func migrate(source: LabelMap,
                                sourceVolume: ImageVolume,
                                targetVolume: ImageVolume,
                                transform: Transform3D = .identity) -> LabelMap {
        let out = LabelMap(parentSeriesUID: targetVolume.seriesUID,
                           depth: targetVolume.depth,
                           height: targetVolume.height,
                           width: targetVolume.width,
                           name: "\(source.name) (migrated)",
                           classes: source.classes)

        for z in 0..<targetVolume.depth {
            for y in 0..<targetVolume.height {
                let rowStart = z * targetVolume.height * targetVolume.width + y * targetVolume.width
                for x in 0..<targetVolume.width {
                    let tgtWorld = targetVolume.worldPoint(z: z, y: y, x: x)
                    let srcWorld = transform.apply(to: tgtWorld)
                    let srcVoxel = sourceVolume.voxelCoordinates(from: srcWorld)
                    let sx = Int(round(srcVoxel.x))
                    let sy = Int(round(srcVoxel.y))
                    let sz = Int(round(srcVoxel.z))

                    if sz >= 0 && sz < source.depth
                        && sy >= 0 && sy < source.height
                        && sx >= 0 && sx < source.width {
                        let srcIdx = source.index(z: sz, y: sy, x: sx)
                        out.voxels[rowStart + x] = source.voxels[srcIdx]
                    }
                }
            }
        }

        out.opacity = source.opacity
        return out
    }

    /// Migrate labels assuming the two volumes share the same world coordinates
    /// (common when both are derived from the same study, e.g. PET and CT
    /// reconstructed to matching grids by the scanner).
    public static func migrateAligned(source: LabelMap,
                                       sourceVolume: ImageVolume,
                                       targetVolume: ImageVolume) -> LabelMap {
        migrate(source: source, sourceVolume: sourceVolume,
                targetVolume: targetVolume, transform: .identity)
    }
}

/// Resample an intensity volume through a transform (linear interpolation).
public enum VolumeResampler {

    public static func resample(source: ImageVolume,
                                 target: ImageVolume,
                                 transform: Transform3D = .identity) -> ImageVolume {
        var out = [Float](repeating: 0, count: target.depth * target.height * target.width)

        for z in 0..<target.depth {
            for y in 0..<target.height {
                let rowStart = z * target.height * target.width + y * target.width
                for x in 0..<target.width {
                    let tgtWorld = target.worldPoint(z: z, y: y, x: x)
                    let srcWorld = transform.apply(to: tgtWorld)
                    let srcVoxel = source.voxelCoordinates(from: srcWorld)

                    if let v = trilinear(source, x: srcVoxel.x, y: srcVoxel.y, z: srcVoxel.z) {
                        out[rowStart + x] = v
                    }
                }
            }
        }

        return ImageVolume(
            pixels: out,
            depth: target.depth,
            height: target.height,
            width: target.width,
            spacing: target.spacing,
            origin: target.origin,
            direction: target.direction,
            modality: source.modality,
            seriesUID: source.seriesUID + "_resampled",
            studyUID: source.studyUID,
            patientID: source.patientID,
            patientName: source.patientName,
            seriesDescription: source.seriesDescription + " (resampled)",
            studyDescription: source.studyDescription,
            suvScaleFactor: source.suvScaleFactor
        )
    }

    @inline(__always)
    private static func trilinear(_ v: ImageVolume, x: Double, y: Double, z: Double) -> Float? {
        let x0 = Int(floor(x)), y0 = Int(floor(y)), z0 = Int(floor(z))
        let x1 = x0 + 1, y1 = y0 + 1, z1 = z0 + 1
        guard x0 >= 0, y0 >= 0, z0 >= 0,
              x1 < v.width, y1 < v.height, z1 < v.depth else { return nil }

        let dx = Float(x - Double(x0))
        let dy = Float(y - Double(y0))
        let dz = Float(z - Double(z0))

        func at(_ xi: Int, _ yi: Int, _ zi: Int) -> Float {
            v.pixels[zi * v.height * v.width + yi * v.width + xi]
        }

        let c00 = at(x0, y0, z0) * (1 - dx) + at(x1, y0, z0) * dx
        let c01 = at(x0, y0, z1) * (1 - dx) + at(x1, y0, z1) * dx
        let c10 = at(x0, y1, z0) * (1 - dx) + at(x1, y1, z0) * dx
        let c11 = at(x0, y1, z1) * (1 - dx) + at(x1, y1, z1) * dx

        let c0 = c00 * (1 - dy) + c10 * dy
        let c1 = c01 * (1 - dy) + c11 * dy

        return c0 * (1 - dz) + c1 * dz
    }
}
