import Foundation
import simd

/// Describes how a raw orthogonal slice should be mirrored before display.
///
/// `ImageVolume.slice(axis:index:)` returns voxel-order pixels. For clinical
/// display we orient those pixels to a consistent radiological convention:
/// axial and coronal show patient left on screen-right, sagittal shows
/// posterior on screen-right, and head/anterior remain in the expected
/// screen positions. The decision is driven from direction cosines so DICOMs
/// with opposite row/column signs do not silently display A/P or R/L reversed.
public struct SliceDisplayTransform: Equatable, Sendable {
    public let flipHorizontal: Bool
    public let flipVertical: Bool

    public init(flipHorizontal: Bool = false, flipVertical: Bool = false) {
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
    }

    public static let identity = SliceDisplayTransform()

    public static func canonical(axis: Int, volume: ImageVolume) -> SliceDisplayTransform {
        let axes = rawDisplayAxes(axis: axis, volume: volume)
        return SliceDisplayTransform(
            flipHorizontal: patientLetter(for: axes.right) != targetRightLetter(axis: axis),
            flipVertical: patientLetter(for: axes.down) != targetDownLetter(axis: axis)
        )
    }

    public static func displayAxes(axis: Int, volume: ImageVolume) -> (right: SIMD3<Double>, down: SIMD3<Double>) {
        let axes = rawDisplayAxes(axis: axis, volume: volume)
        let transform = canonical(axis: axis, volume: volume)
        return (
            right: transform.flipHorizontal ? -axes.right : axes.right,
            down: transform.flipVertical ? -axes.down : axes.down
        )
    }

    private static func rawDisplayAxes(axis: Int, volume: ImageVolume) -> (right: SIMD3<Double>, down: SIMD3<Double>) {
        switch axis {
        case 0:
            return (right: volume.direction[1], down: volume.direction[2])
        case 1:
            return (right: volume.direction[0], down: volume.direction[2])
        default:
            return (right: volume.direction[0], down: volume.direction[1])
        }
    }

    private static func targetRightLetter(axis: Int) -> String {
        switch axis {
        case 0: return "P"
        default: return "L"
        }
    }

    private static func targetDownLetter(axis: Int) -> String {
        switch axis {
        case 2: return "P"
        default: return "F"
        }
    }

    public static func patientLetter(for vector: SIMD3<Double>) -> String {
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
}
