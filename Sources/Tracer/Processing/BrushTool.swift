import Foundation

/// Paint/erase operations on a `LabelMap`. All mutations happen in-place;
/// callers should publish change notifications afterwards.
public enum BrushTool {

    public enum Mode {
        case paint   // assign classID
        case erase   // zero out (regardless of current value)
        case eraseClass  // only erase voxels currently matching the target class
    }

    /// Paint a 2D circular brush stroke on one slice.
    public static func paint2D(label: LabelMap,
                                axis: Int,
                                sliceIndex: Int,
                                pixelX: Int, pixelY: Int,
                                radius: Int,
                                classID: UInt16,
                                mode: Mode = .paint) {
        let r2 = radius * radius
        for dy in -radius...radius {
            for dx in -radius...radius {
                if dx*dx + dy*dy > r2 { continue }
                let (z, y, x) = coordFor(axis: axis,
                                         sliceIndex: sliceIndex,
                                         pixelX: pixelX + dx,
                                         pixelY: pixelY + dy)
                apply(label: label, z: z, y: y, x: x, classID: classID, mode: mode)
            }
        }
    }

    /// Paint a 3D spherical brush stroke (useful for thick brushes).
    public static func paint3D(label: LabelMap,
                                z: Int, y: Int, x: Int,
                                radius: Int,
                                classID: UInt16,
                                mode: Mode = .paint) {
        let r2 = radius * radius
        for dz in -radius...radius {
            for dy in -radius...radius {
                for dx in -radius...radius {
                    if dx*dx + dy*dy + dz*dz > r2 { continue }
                    apply(label: label, z: z+dz, y: y+dy, x: x+dx,
                          classID: classID, mode: mode)
                }
            }
        }
    }

    /// Connect two points with a line of circular brushes (smooth stroke).
    public static func paintLine(label: LabelMap,
                                  axis: Int,
                                  sliceIndex: Int,
                                  fromX: Int, fromY: Int,
                                  toX: Int, toY: Int,
                                  radius: Int,
                                  classID: UInt16,
                                  mode: Mode = .paint) {
        let dx = toX - fromX
        let dy = toY - fromY
        let dist = max(1, Int(sqrt(Double(dx*dx + dy*dy))))
        let steps = max(1, dist)
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let px = fromX + Int(Double(dx) * t)
            let py = fromY + Int(Double(dy) * t)
            paint2D(label: label,
                    axis: axis, sliceIndex: sliceIndex,
                    pixelX: px, pixelY: py,
                    radius: radius, classID: classID, mode: mode)
        }
    }

    // MARK: - helpers

    private static func coordFor(axis: Int, sliceIndex: Int,
                                  pixelX: Int, pixelY: Int) -> (z: Int, y: Int, x: Int) {
        switch axis {
        case 0: return (z: pixelY, y: pixelX, x: sliceIndex)
        case 1: return (z: pixelY, y: sliceIndex, x: pixelX)
        default: return (z: sliceIndex, y: pixelY, x: pixelX)
        }
    }

    private static func apply(label: LabelMap, z: Int, y: Int, x: Int,
                               classID: UInt16, mode: Mode) {
        guard z >= 0, z < label.depth, y >= 0, y < label.height, x >= 0, x < label.width else { return }
        let idx = label.index(z: z, y: y, x: x)
        switch mode {
        case .paint:
            label.voxels[idx] = classID
        case .erase:
            label.voxels[idx] = 0
        case .eraseClass:
            if label.voxels[idx] == classID {
                label.voxels[idx] = 0
            }
        }
    }
}
