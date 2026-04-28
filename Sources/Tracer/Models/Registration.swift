import Foundation
import simd

/// A rigid/affine transform expressed as a 4×4 matrix in LPS space.
public struct Transform3D: Sendable {
    public var matrix: simd_double4x4

    public init(matrix: simd_double4x4 = matrix_identity_double4x4) {
        self.matrix = matrix
    }

    public static var identity: Transform3D { .init(matrix: matrix_identity_double4x4) }

    // MARK: - Constructors

    /// Translation in mm.
    public static func translation(_ tx: Double, _ ty: Double, _ tz: Double) -> Transform3D {
        var m = matrix_identity_double4x4
        m[3, 0] = tx
        m[3, 1] = ty
        m[3, 2] = tz
        return Transform3D(matrix: m)
    }

    /// Rotation around the X axis (radians).
    public static func rotationX(_ angle: Double) -> Transform3D {
        let c = cos(angle), s = sin(angle)
        var m = matrix_identity_double4x4
        m[1, 1] =  c; m[2, 1] = s
        m[1, 2] = -s; m[2, 2] = c
        return Transform3D(matrix: m)
    }

    public static func rotationY(_ angle: Double) -> Transform3D {
        let c = cos(angle), s = sin(angle)
        var m = matrix_identity_double4x4
        m[0, 0] = c; m[2, 0] = -s
        m[0, 2] = s; m[2, 2] =  c
        return Transform3D(matrix: m)
    }

    public static func rotationZ(_ angle: Double) -> Transform3D {
        let c = cos(angle), s = sin(angle)
        var m = matrix_identity_double4x4
        m[0, 0] =  c; m[1, 0] = s
        m[0, 1] = -s; m[1, 1] = c
        return Transform3D(matrix: m)
    }

    /// Uniform scale around the world origin.
    public static func scale(_ factor: Double) -> Transform3D {
        var m = matrix_identity_double4x4
        m[0, 0] = factor
        m[1, 1] = factor
        m[2, 2] = factor
        return Transform3D(matrix: m)
    }

    /// Axis-specific scale around the world origin.
    public static func scale(_ factors: SIMD3<Double>) -> Transform3D {
        var m = matrix_identity_double4x4
        m[0, 0] = factors.x
        m[1, 1] = factors.y
        m[2, 2] = factors.z
        return Transform3D(matrix: m)
    }

    /// Build a rigid transform from Euler angles (radians) + translation (mm).
    public static func rigid(tx: Double, ty: Double, tz: Double,
                              rx: Double, ry: Double, rz: Double) -> Transform3D {
        let r = rotationX(rx).matrix * rotationY(ry).matrix * rotationZ(rz).matrix
        var m = r
        m[3, 0] = tx
        m[3, 1] = ty
        m[3, 2] = tz
        return Transform3D(matrix: m)
    }

    // MARK: - Operations

    public func apply(to p: SIMD3<Double>) -> SIMD3<Double> {
        let v = matrix * SIMD4<Double>(p.x, p.y, p.z, 1)
        return SIMD3<Double>(v.x, v.y, v.z)
    }

    public var inverse: Transform3D {
        Transform3D(matrix: matrix.inverse)
    }

    public func concatenate(_ other: Transform3D) -> Transform3D {
        Transform3D(matrix: matrix * other.matrix)
    }
}

// MARK: - Landmark-based registration

/// Paired points used for landmark registration.
public struct LandmarkPair: Identifiable {
    public let id = UUID()
    public var fixed: SIMD3<Double>    // LPS world point in reference volume
    public var moving: SIMD3<Double>   // LPS world point in moving volume
    public var label: String = ""

    public init(fixed: SIMD3<Double>, moving: SIMD3<Double>, label: String = "") {
        self.fixed = fixed
        self.moving = moving
        self.label = label
    }
}

public enum LandmarkRegistration {

    /// Compute best-fit rigid transform (mov → fixed) using SVD (Horn 1987).
    /// Returns identity on insufficient data.
    public static func rigid(landmarks: [LandmarkPair]) -> Transform3D {
        guard landmarks.count >= 3 else { return .identity }

        let n = Double(landmarks.count)
        var centroidFixed = SIMD3<Double>(0, 0, 0)
        var centroidMoving = SIMD3<Double>(0, 0, 0)
        for lm in landmarks {
            centroidFixed += lm.fixed
            centroidMoving += lm.moving
        }
        centroidFixed /= n
        centroidMoving /= n

        // Cross-covariance matrix H = sum (mov_i - mean_mov) * (fixed_i - mean_fixed)^T
        var H = simd_double3x3(0)
        for lm in landmarks {
            let p = lm.moving - centroidMoving
            let q = lm.fixed - centroidFixed
            H = H + simd_double3x3(
                SIMD3<Double>(p.x * q.x, p.x * q.y, p.x * q.z),
                SIMD3<Double>(p.y * q.x, p.y * q.y, p.y * q.z),
                SIMD3<Double>(p.z * q.x, p.z * q.y, p.z * q.z)
            )
        }

        // SVD via symmetric Jacobi eigendecomposition on H^T H to get V, Σ, and
        // U = H V Σ^-1. For numerical stability we use a simple analytic approach
        // by eigendecomposing H^T * H.
        let HtH = H.transpose * H
        let (eigVals, V) = symmetricEigen(HtH)

        // Build Σ and U
        var sigma = SIMD3<Double>(
            sqrt(max(eigVals.x, 0)),
            sqrt(max(eigVals.y, 0)),
            sqrt(max(eigVals.z, 0))
        )
        // Avoid division by zero
        for i in 0..<3 {
            if sigma[i] < 1e-12 { sigma[i] = 1e-12 }
        }
        let invSigma = simd_double3x3(diagonal: SIMD3<Double>(1/sigma.x, 1/sigma.y, 1/sigma.z))
        var U = H * V * invSigma

        // Ensure proper rotation (det = +1, not -1 which is reflection)
        let R0 = U * V.transpose
        if simd_determinant(R0) < 0 {
            var Ucol2 = SIMD3<Double>(U[0, 2], U[1, 2], U[2, 2])
            Ucol2 = -Ucol2
            U[0, 2] = Ucol2.x; U[1, 2] = Ucol2.y; U[2, 2] = Ucol2.z
        }
        let R = U * V.transpose
        let t = centroidFixed - R * centroidMoving

        var M = matrix_identity_double4x4
        M[0, 0] = R[0, 0]; M[1, 0] = R[1, 0]; M[2, 0] = R[2, 0]
        M[0, 1] = R[0, 1]; M[1, 1] = R[1, 1]; M[2, 1] = R[2, 1]
        M[0, 2] = R[0, 2]; M[1, 2] = R[1, 2]; M[2, 2] = R[2, 2]
        M[3, 0] = t.x
        M[3, 1] = t.y
        M[3, 2] = t.z
        return Transform3D(matrix: M)
    }

    /// Compute root-mean-square target registration error (in mm).
    public static func tre(_ transform: Transform3D, landmarks: [LandmarkPair]) -> Double {
        guard !landmarks.isEmpty else { return 0 }
        var sumSq = 0.0
        for lm in landmarks {
            let mapped = transform.apply(to: lm.moving)
            let diff = mapped - lm.fixed
            sumSq += simd_dot(diff, diff)
        }
        return sqrt(sumSq / Double(landmarks.count))
    }

    // MARK: - Simple Jacobi eigendecomposition for 3x3 symmetric

    private static func symmetricEigen(_ A: simd_double3x3) -> (SIMD3<Double>, simd_double3x3) {
        var a = A
        var V = matrix_identity_double3x3
        let maxIter = 50
        let eps = 1e-12

        for _ in 0..<maxIter {
            // Find largest off-diagonal element
            var p = 0, q = 1
            var maxOff = abs(a[1, 0])
            if abs(a[2, 0]) > maxOff { maxOff = abs(a[2, 0]); p = 0; q = 2 }
            if abs(a[2, 1]) > maxOff { maxOff = abs(a[2, 1]); p = 1; q = 2 }
            if maxOff < eps { break }

            // Compute Jacobi rotation
            let theta = (a[q, q] - a[p, p]) / (2 * a[q, p])
            let t: Double = theta >= 0
                ? 1 / (theta + sqrt(1 + theta * theta))
                : 1 / (theta - sqrt(1 + theta * theta))
            let c = 1 / sqrt(1 + t * t)
            let s = t * c

            // Apply rotation to a
            var aNew = a
            aNew[p, p] = c*c*a[p,p] - 2*s*c*a[q,p] + s*s*a[q,q]
            aNew[q, q] = s*s*a[p,p] + 2*s*c*a[q,p] + c*c*a[q,q]
            aNew[q, p] = 0
            aNew[p, q] = 0
            for k in 0..<3 where k != p && k != q {
                aNew[k, p] = c*a[k,p] - s*a[k,q]
                aNew[p, k] = aNew[k, p]
                aNew[k, q] = s*a[k,p] + c*a[k,q]
                aNew[q, k] = aNew[k, q]
            }
            a = aNew

            // Accumulate into V
            var Vnew = V
            for k in 0..<3 {
                Vnew[p, k] = c*V[p,k] - s*V[q,k]
                Vnew[q, k] = s*V[p,k] + c*V[q,k]
            }
            V = Vnew
        }

        // Sort eigenvalues descending
        let eigVals = SIMD3<Double>(a[0, 0], a[1, 1], a[2, 2])
        return (eigVals, V)
    }
}
