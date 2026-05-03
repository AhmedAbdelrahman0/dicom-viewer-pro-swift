import Foundation

/// Semi-automatic **level-set segmentation** implemented from scratch in
/// Swift, modeled on the algorithm described in:
///
///   Yushkevich, Piven, Hazlett, Smith, Ho, Gee, Gerig. 2006.
///   *User-Guided 3D Active Contour Segmentation of Anatomical Structures*.
///   NeuroImage 31(3): 1116–1128.
///
/// This implementation is an independent Swift port of the math. License here
/// is the same as the rest of Tracer.
///
/// ### Pipeline
///
/// 1. **Speed image** `F(x) ∈ [-1, 1]` derived from the intensity volume.
///    Two modes:
///      - `regionCompetition` — smooth thresholding around a foreground
///        intensity range; positive inside the region of interest, negative
///        outside. Good for bright-object-on-dark-background (tumors,
///        organs in CT).
///      - `edgeStopping` — `1 / (1 + (|∇I| / κ)²)`. Close to zero where the
///        image gradient is strong, so the front slows at edges.
///
/// 2. **Initialization** — bubble(s) seeded by the caller (center + radius
///    voxels). The initial signed-distance field φ is just
///    `‖x - seed‖ - r`.
///
/// 3. **Evolution** — iterate
///       `∂φ/∂t = -α F |∇φ| + β F κ |∇φ| + γ ∇F · ∇φ`
///    where κ is mean curvature. α is the propagation weight, β the
///    curvature regularizer, γ the advection weight. Up-wind scheme for the
///    advection term; 6-neighbor differences for the rest. This is the
///    narrow-band scheme linearized over the whole volume (acceptable for
///    small-to-medium volumes; a proper narrow band can be added later).
///
/// 4. **Output** — a `LabelMap` where `φ ≤ 0` becomes the selected class id.
public enum LevelSetSegmentation {

    // MARK: - Public API

    public enum SpeedMode: Sendable {
        /// Smooth thresholding: `tanh` centered at `midpoint`, steepness
        /// scaled by `halfWidth`. `(volume - midpoint) / halfWidth ↦ tanh`.
        case regionCompetition(midpoint: Float, halfWidth: Float)
        /// Edge-stopping: `1 / (1 + (|∇I|/kappa)²)`. Larger kappa → softer
        /// stopping. This mode yields F ∈ [0, 1]; the evolution auto-shifts
        /// to [-1, 1] by subtracting the mean.
        case edgeStopping(kappa: Float)
    }

    public struct Parameters: Sendable {
        /// Propagation weight α. Positive = expand into positive-speed
        /// region. Typical range: 0.5 … 2.0.
        public var propagation: Float = 1.0
        /// Curvature weight β. Higher = smoother contour. Typical: 0.1 … 0.5.
        public var curvature: Float = 0.2
        /// Advection weight γ (drift toward edges).
        public var advection: Float = 0.5
        /// Time step Δt. Must be ≤ 0.5 / (max speed) for CFL stability.
        public var timeStep: Float = 0.25
        /// Maximum number of update iterations.
        public var iterations: Int = 200
        /// Early-stop: stop when per-iteration RMS change of φ drops below
        /// this. Set to 0 to disable.
        public var convergenceTolerance: Float = 1e-3

        public init(propagation: Float = 1.0,
                    curvature: Float = 0.2,
                    advection: Float = 0.5,
                    timeStep: Float = 0.25,
                    iterations: Int = 200,
                    convergenceTolerance: Float = 1e-3) {
            self.propagation = propagation
            self.curvature = curvature
            self.advection = advection
            self.timeStep = timeStep
            self.iterations = iterations
            self.convergenceTolerance = convergenceTolerance
        }
    }

    public struct Seed: Sendable {
        public let z: Int
        public let y: Int
        public let x: Int
        public let radius: Int

        public init(z: Int, y: Int, x: Int, radius: Int) {
            self.z = z; self.y = y; self.x = x; self.radius = radius
        }
    }

    public struct Result: Sendable {
        /// Number of voxels marked as inside (φ ≤ 0).
        public let insideVoxels: Int
        /// Final iteration count before stopping.
        public let iterations: Int
        /// Last observed RMS change of φ.
        public let finalRMS: Float
        /// Whether convergence (RMS < tolerance) was reached.
        public let converged: Bool
    }

    /// Run a level-set evolution and paint the result into `label` at `classID`.
    @discardableResult
    public static func evolve(volume: ImageVolume,
                              label: LabelMap,
                              seeds: [Seed],
                              speed: SpeedMode,
                              parameters: Parameters = Parameters(),
                              classID: UInt16) -> Result {
        guard volume.width == label.width,
              volume.height == label.height,
              volume.depth == label.depth
        else {
            return Result(insideVoxels: 0,
                          iterations: 0,
                          finalRMS: .infinity,
                          converged: false)
        }

        let w = volume.width, h = volume.height, d = volume.depth
        let count = w * h * d
        guard volume.pixels.count == count, label.voxels.count == count else {
            return Result(insideVoxels: 0,
                          iterations: 0,
                          finalRMS: .infinity,
                          converged: false)
        }

        var phi = signedDistanceField(from: seeds, width: w, height: h, depth: d)
        func paintInside(from phi: [Float]) -> Int {
            var inside = 0
            for i in 0..<count where phi[i] <= 0 {
                label.voxels[i] = classID
                inside += 1
            }
            return inside
        }

        guard w >= 3, h >= 3, d >= 3 else {
            let inside = paintInside(from: phi)
            return Result(insideVoxels: inside,
                          iterations: 0,
                          finalRMS: 0,
                          converged: false)
        }

        let F = buildSpeedField(from: volume.pixels,
                                width: w, height: h, depth: d,
                                mode: speed)
        let (gFx, gFy, gFz) = gradient(of: F, width: w, height: h, depth: d)

        let alpha = parameters.propagation
        let beta = parameters.curvature
        let gamma = parameters.advection
        let dt = max(Float(1e-4), parameters.timeStep)

        var finalRMS: Float = .infinity
        var actualIters = 0
        var converged = false

        for iter in 1...max(1, parameters.iterations) {
            actualIters = iter
            var rmsNumerator: Double = 0
            var newPhi = phi

            for z in 1..<(d - 1) {
                for y in 1..<(h - 1) {
                    let rowStart = z * h * w + y * w
                    for x in 1..<(w - 1) {
                        let i = rowStart + x

                        // First derivatives (central differences).
                        let dxp = phi[i + 1] - phi[i]
                        let dxm = phi[i] - phi[i - 1]
                        let dyp = phi[i + w] - phi[i]
                        let dym = phi[i] - phi[i - w]
                        let dzp = phi[i + w * h] - phi[i]
                        let dzm = phi[i] - phi[i - w * h]

                        let dx = 0.5 * (dxp + dxm)
                        let dy = 0.5 * (dyp + dym)
                        let dz = 0.5 * (dzp + dzm)
                        let gradMag = sqrtf(dx * dx + dy * dy + dz * dz) + 1e-6

                        // Second derivatives for curvature.
                        let dxx = phi[i + 1] - 2 * phi[i] + phi[i - 1]
                        let dyy = phi[i + w] - 2 * phi[i] + phi[i - w]
                        let dzz = phi[i + w * h] - 2 * phi[i] + phi[i - w * h]
                        // Mean curvature κ = ∇·(∇φ / |∇φ|).
                        let kappa = (dxx + dyy + dzz) / gradMag

                        // Upwind gradient magnitude for propagation term
                        // (Osher-Sethian scheme).
                        let Fi = F[i]
                        let propGrad: Float
                        if Fi > 0 {
                            let a = max(dxm, 0), b = min(dxp, 0)
                            let c = max(dym, 0), e = min(dyp, 0)
                            let f2 = max(dzm, 0), g2 = min(dzp, 0)
                            propGrad = sqrtf(a*a + b*b + c*c + e*e + f2*f2 + g2*g2)
                        } else {
                            let a = min(dxm, 0), b = max(dxp, 0)
                            let c = min(dym, 0), e = max(dyp, 0)
                            let f2 = min(dzm, 0), g2 = max(dzp, 0)
                            propGrad = sqrtf(a*a + b*b + c*c + e*e + f2*f2 + g2*g2)
                        }

                        // Advection: -γ ∇F · ∇φ with upwind on the sign of each
                        // component of ∇F.
                        let ax = gFx[i]
                        let ay = gFy[i]
                        let az = gFz[i]
                        let advec = ax * (ax > 0 ? dxm : dxp)
                                  + ay * (ay > 0 ? dym : dyp)
                                  + az * (az > 0 ? dzm : dzp)

                        let update = -alpha * Fi * propGrad
                                   + beta * Fi * kappa * gradMag
                                   + gamma * advec

                        let next = phi[i] + dt * update
                        newPhi[i] = next
                        let delta = next - phi[i]
                        rmsNumerator += Double(delta * delta)
                    }
                }
            }

            phi = newPhi
            let rms = Float(sqrt(rmsNumerator / Double(max(1, count))))
            finalRMS = rms
            if parameters.convergenceTolerance > 0,
               rms < parameters.convergenceTolerance {
                converged = true
                break
            }
        }

        // Paint the inside voxels (φ ≤ 0) into the label map.
        let inside = paintInside(from: phi)

        return Result(insideVoxels: inside,
                      iterations: actualIters,
                      finalRMS: finalRMS,
                      converged: converged)
    }

    // MARK: - Speed fields

    public static func buildSpeedField(from pixels: [Float],
                                       width w: Int, height h: Int, depth d: Int,
                                       mode: SpeedMode) -> [Float] {
        switch mode {
        case .regionCompetition(let mid, let halfWidth):
            let hw = max(Float(1e-6), halfWidth)
            return pixels.map { v in tanhf((v - mid) / hw) }

        case .edgeStopping(let kappa):
            // Image gradient magnitude, then 1 / (1 + (g/κ)²).
            var grad = [Float](repeating: 0, count: pixels.count)
            let wH = w * h
            for z in 0..<d {
                for y in 0..<h {
                    for x in 0..<w {
                        let i = z * wH + y * w + x
                        let xp = pixels[i + (x < w - 1 ? 1 : 0)]
                        let xm = pixels[i - (x > 0 ? 1 : 0)]
                        let yp = pixels[i + (y < h - 1 ? w : 0)]
                        let ym = pixels[i - (y > 0 ? w : 0)]
                        let zp = pixels[i + (z < d - 1 ? wH : 0)]
                        let zm = pixels[i - (z > 0 ? wH : 0)]
                        let gx = 0.5 * (xp - xm)
                        let gy = 0.5 * (yp - ym)
                        let gz = 0.5 * (zp - zm)
                        grad[i] = sqrtf(gx * gx + gy * gy + gz * gz)
                    }
                }
            }
            let k = max(Float(1e-6), kappa)
            let raw = grad.map { g -> Float in
                let r = g / k
                return 1 / (1 + r * r)
            }
            // Shift to [-1, 1]-ish by centering around the mean.
            let mean = raw.reduce(0, +) / Float(raw.count)
            return raw.map { ($0 - mean) * 2 }
        }
    }

    // MARK: - Private helpers

    static func signedDistanceField(from seeds: [Seed],
                                    width w: Int, height h: Int, depth d: Int) -> [Float] {
        var phi = [Float](repeating: .infinity, count: w * h * d)
        for z in 0..<d {
            for y in 0..<h {
                let row = z * h * w + y * w
                for x in 0..<w {
                    var best = Float.infinity
                    for seed in seeds {
                        let dz = Float(z - seed.z)
                        let dy = Float(y - seed.y)
                        let dx = Float(x - seed.x)
                        let dist = sqrtf(dz * dz + dy * dy + dx * dx) - Float(max(1, seed.radius))
                        if dist < best { best = dist }
                    }
                    phi[row + x] = best
                }
            }
        }
        return phi
    }

    static func gradient(of field: [Float],
                         width w: Int, height h: Int, depth d: Int) -> ([Float], [Float], [Float]) {
        var gx = [Float](repeating: 0, count: field.count)
        var gy = [Float](repeating: 0, count: field.count)
        var gz = [Float](repeating: 0, count: field.count)
        let wH = w * h
        for z in 0..<d {
            for y in 0..<h {
                for x in 0..<w {
                    let i = z * wH + y * w + x
                    let xp = field[i + (x < w - 1 ? 1 : 0)]
                    let xm = field[i - (x > 0 ? 1 : 0)]
                    let yp = field[i + (y < h - 1 ? w : 0)]
                    let ym = field[i - (y > 0 ? w : 0)]
                    let zp = field[i + (z < d - 1 ? wH : 0)]
                    let zm = field[i - (z > 0 ? wH : 0)]
                    gx[i] = 0.5 * (xp - xm)
                    gy[i] = 0.5 * (yp - ym)
                    gz[i] = 0.5 * (zp - zm)
                }
            }
        }
        return (gx, gy, gz)
    }
}
