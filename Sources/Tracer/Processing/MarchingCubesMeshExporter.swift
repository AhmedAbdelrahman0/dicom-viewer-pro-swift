import Foundation
import simd

/// Surface-mesh export for label maps, using a compact marching-cubes
/// implementation. Produces binary STL and ASCII OBJ files — the two formats
/// most commonly ingested by 3D-print slicers and surface-analysis tools.
///
/// This is an independent Swift implementation based on the original 1987
/// marching-cubes paper (Lorensen & Cline); the 256-case edge/triangle
/// tables are the well-known public-domain tables.
///
/// For multi-label masks, call `exportAllClasses(...)` — each class produces
/// a separate mesh file (STL/OBJ) in the output directory.
public enum MarchingCubesMeshExporter {

    public enum Format: String, CaseIterable, Identifiable, Sendable {
        case stl
        case obj

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .stl: return "STL"
            case .obj: return "OBJ"
            }
        }

        public var fileExtension: String { rawValue }
    }

    public struct ExportOptions: Sendable {
        public var format: Format = .stl
        /// Smooth vertices by averaging with their neighbors on the surface
        /// adjacency graph. 0 = off. 1 … 3 is typical.
        public var smoothingIterations: Int = 0
        /// When true, vertices are expressed in world (mm) coordinates
        /// using the volume's spacing/origin/direction. When false, mesh
        /// is in voxel-index space.
        public var useWorldCoordinates: Bool = true

        public init(format: Format = .stl,
                    smoothingIterations: Int = 0,
                    useWorldCoordinates: Bool = true) {
            self.format = format
            self.smoothingIterations = smoothingIterations
            self.useWorldCoordinates = useWorldCoordinates
        }
    }

    public struct ExportedMesh: Sendable {
        public let classID: UInt16
        public let className: String
        public let url: URL
        public let triangleCount: Int
    }

    // MARK: - Public API

    /// Export a single class's surface to `url`.
    @discardableResult
    public static func exportClass(label: LabelMap,
                                   volume: ImageVolume,
                                   classID: UInt16,
                                   to url: URL,
                                   options: ExportOptions = ExportOptions()) throws -> ExportedMesh {
        let mesh = buildMesh(label: label,
                             volume: volume,
                             classID: classID,
                             options: options)
        try writeMesh(mesh, to: url, format: options.format,
                      className: label.classInfo(id: classID)?.name
                          ?? "class-\(classID)")

        let className = label.classInfo(id: classID)?.name ?? "class-\(classID)"
        return ExportedMesh(classID: classID,
                            className: className,
                            url: url,
                            triangleCount: mesh.triangles.count)
    }

    /// Export every non-background class into `directory`, one file per class.
    @discardableResult
    public static func exportAllClasses(label: LabelMap,
                                        volume: ImageVolume,
                                        to directory: URL,
                                        options: ExportOptions = ExportOptions()) throws -> [ExportedMesh] {
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        var exports: [ExportedMesh] = []
        for cls in label.classes where cls.labelID != 0 {
            let safe = sanitize(cls.name)
            let ext = (options.format == .stl) ? "stl" : "obj"
            let file = directory.appendingPathComponent("\(safe)-\(cls.labelID).\(ext)")
            exports.append(try exportClass(label: label,
                                           volume: volume,
                                           classID: cls.labelID,
                                           to: file,
                                           options: options))
        }
        return exports
    }

    // MARK: - Mesh building

    private struct Mesh {
        var vertices: [SIMD3<Float>] = []
        var triangles: [(Int, Int, Int)] = []
    }

    private static func buildMesh(label: LabelMap,
                                  volume: ImageVolume,
                                  classID: UInt16,
                                  options: ExportOptions) -> Mesh {
        // Binary mask ∈ {0, 1} at each voxel — 1 if label == classID.
        let w = label.width, h = label.height, d = label.depth
        let stride = w * h

        @inline(__always)
        func inside(_ x: Int, _ y: Int, _ z: Int) -> Float {
            guard x >= 0, x < w, y >= 0, y < h, z >= 0, z < d else { return 0 }
            return label.voxels[z * stride + y * w + x] == classID ? 1 : 0
        }

        var mesh = Mesh()
        var edgeCache: [UInt64: Int] = [:]

        for z in 0..<(d - 1) {
            for y in 0..<(h - 1) {
                for x in 0..<(w - 1) {
                    let v0 = inside(x,     y,     z    )
                    let v1 = inside(x + 1, y,     z    )
                    let v2 = inside(x + 1, y + 1, z    )
                    let v3 = inside(x,     y + 1, z    )
                    let v4 = inside(x,     y,     z + 1)
                    let v5 = inside(x + 1, y,     z + 1)
                    let v6 = inside(x + 1, y + 1, z + 1)
                    let v7 = inside(x,     y + 1, z + 1)

                    var caseIndex = 0
                    if v0 > 0.5 { caseIndex |= 1   }
                    if v1 > 0.5 { caseIndex |= 2   }
                    if v2 > 0.5 { caseIndex |= 4   }
                    if v3 > 0.5 { caseIndex |= 8   }
                    if v4 > 0.5 { caseIndex |= 16  }
                    if v5 > 0.5 { caseIndex |= 32  }
                    if v6 > 0.5 { caseIndex |= 64  }
                    if v7 > 0.5 { caseIndex |= 128 }

                    let edges = edgeTable[caseIndex]
                    if edges == 0 { continue }

                    // Compute vertex positions on each intersected edge.
                    // Edge table maps bit N → endpoints of cube edge N.
                    let corners: [SIMD3<Float>] = [
                        SIMD3(Float(x),     Float(y),     Float(z)),
                        SIMD3(Float(x + 1), Float(y),     Float(z)),
                        SIMD3(Float(x + 1), Float(y + 1), Float(z)),
                        SIMD3(Float(x),     Float(y + 1), Float(z)),
                        SIMD3(Float(x),     Float(y),     Float(z + 1)),
                        SIMD3(Float(x + 1), Float(y),     Float(z + 1)),
                        SIMD3(Float(x + 1), Float(y + 1), Float(z + 1)),
                        SIMD3(Float(x),     Float(y + 1), Float(z + 1)),
                    ]
                    let values: [Float] = [v0, v1, v2, v3, v4, v5, v6, v7]

                    var edgeVertIndex = [Int](repeating: -1, count: 12)
                    for e in 0..<12 where (edges & (1 << e)) != 0 {
                        let (a, b) = edgeCornerPairs[e]
                        let p1 = corners[a]
                        let p2 = corners[b]
                        let v1v = values[a]
                        let v2v = values[b]

                        // Edge key uses absolute voxel indices for dedup.
                        let key = edgeKey(corner1: cornerVoxelIndex(e: e, a: a, x: x, y: y, z: z),
                                          corner2: cornerVoxelIndex(e: e, a: b, x: x, y: y, z: z))
                        if let existing = edgeCache[key] {
                            edgeVertIndex[e] = existing
                            continue
                        }

                        let t: Float = (0.5 - v1v) / (v2v - v1v + 1e-6)
                        var pos = p1 + t * (p2 - p1)
                        if options.useWorldCoordinates {
                            pos = worldPosition(for: pos, volume: volume)
                        }
                        edgeVertIndex[e] = mesh.vertices.count
                        edgeCache[key] = mesh.vertices.count
                        mesh.vertices.append(pos)
                    }

                    // Emit triangles from the triTable for this case.
                    let tris = triTable[caseIndex]
                    var ti = 0
                    while ti + 2 < tris.count, tris[ti] != -1 {
                        let a = edgeVertIndex[Int(tris[ti])]
                        let b = edgeVertIndex[Int(tris[ti + 1])]
                        let c = edgeVertIndex[Int(tris[ti + 2])]
                        if a >= 0 && b >= 0 && c >= 0 {
                            mesh.triangles.append((a, b, c))
                        }
                        ti += 3
                    }
                }
            }
        }

        if options.smoothingIterations > 0 {
            laplacianSmooth(mesh: &mesh, iterations: options.smoothingIterations)
        }

        return mesh
    }

    // MARK: - Smoothing

    private static func laplacianSmooth(mesh: inout Mesh, iterations: Int) {
        guard iterations > 0, !mesh.vertices.isEmpty else { return }
        var adjacency = [[Int]](repeating: [], count: mesh.vertices.count)
        for (a, b, c) in mesh.triangles {
            adjacency[a].append(b); adjacency[a].append(c)
            adjacency[b].append(a); adjacency[b].append(c)
            adjacency[c].append(a); adjacency[c].append(b)
        }
        for i in 0..<adjacency.count {
            adjacency[i] = Array(Set(adjacency[i]))
        }

        for _ in 0..<iterations {
            var next = mesh.vertices
            for i in 0..<mesh.vertices.count {
                let neighbors = adjacency[i]
                guard !neighbors.isEmpty else { continue }
                var sum = SIMD3<Float>.zero
                for n in neighbors { sum += mesh.vertices[n] }
                next[i] = sum / Float(neighbors.count)
            }
            mesh.vertices = next
        }
    }

    // MARK: - World coords

    private static func worldPosition(for voxel: SIMD3<Float>,
                                      volume: ImageVolume) -> SIMD3<Float> {
        let world = volume.worldPoint(voxel: SIMD3<Double>(
            Double(voxel.x), Double(voxel.y), Double(voxel.z)
        ))
        return SIMD3<Float>(Float(world.x), Float(world.y), Float(world.z))
    }

    // MARK: - Writers

    private static func writeMesh(_ mesh: Mesh,
                                  to url: URL,
                                  format: Format,
                                  className: String) throws {
        switch format {
        case .stl:
            try writeBinarySTL(mesh: mesh, to: url, header: "Tracer \(className)")
        case .obj:
            try writeOBJ(mesh: mesh, to: url, objectName: className)
        }
    }

    private static func writeBinarySTL(mesh: Mesh, to url: URL, header: String) throws {
        var data = Data(count: 80)
        let bytes = Array(header.utf8.prefix(80))
        for (i, b) in bytes.enumerated() { data[i] = b }

        var triCount = UInt32(mesh.triangles.count).littleEndian
        withUnsafeBytes(of: &triCount) { data.append(contentsOf: $0) }

        for (ai, bi, ci) in mesh.triangles {
            let a = mesh.vertices[ai]
            let b = mesh.vertices[bi]
            let c = mesh.vertices[ci]
            let normal = simd_normalize(simd_cross(b - a, c - a))
            appendFloat(normal.x, to: &data)
            appendFloat(normal.y, to: &data)
            appendFloat(normal.z, to: &data)
            appendFloat(a.x, to: &data); appendFloat(a.y, to: &data); appendFloat(a.z, to: &data)
            appendFloat(b.x, to: &data); appendFloat(b.y, to: &data); appendFloat(b.z, to: &data)
            appendFloat(c.x, to: &data); appendFloat(c.y, to: &data); appendFloat(c.z, to: &data)
            var attr: UInt16 = 0
            withUnsafeBytes(of: &attr) { data.append(contentsOf: $0) }
        }

        try data.write(to: url, options: [.atomic])
    }

    private static func writeOBJ(mesh: Mesh, to url: URL, objectName: String) throws {
        var out = ""
        out += "# Tracer label-mesh export\n"
        out += "o \(sanitize(objectName))\n"
        for v in mesh.vertices {
            out += "v \(v.x) \(v.y) \(v.z)\n"
        }
        for (a, b, c) in mesh.triangles {
            // OBJ is 1-indexed.
            out += "f \(a + 1) \(b + 1) \(c + 1)\n"
        }
        try out.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func appendFloat(_ v: Float, to data: inout Data) {
        var le = v.bitPattern.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    // MARK: - Edge/tri tables

    /// Pairs of cube corners that define each of the 12 cube edges.
    private static let edgeCornerPairs: [(Int, Int)] = [
        (0, 1), (1, 2), (2, 3), (3, 0),
        (4, 5), (5, 6), (6, 7), (7, 4),
        (0, 4), (1, 5), (2, 6), (3, 7),
    ]

    private static func cornerVoxelIndex(e: Int, a: Int,
                                         x: Int, y: Int, z: Int) -> (Int, Int, Int) {
        let offsets: [(Int, Int, Int)] = [
            (0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0),
            (0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1),
        ]
        let (dx, dy, dz) = offsets[a]
        return (x + dx, y + dy, z + dz)
    }

    private static func edgeKey(corner1 a: (Int, Int, Int),
                                corner2 b: (Int, Int, Int)) -> UInt64 {
        // Canonicalize order for stable keys regardless of edge direction.
        let (lo, hi): ((Int, Int, Int), (Int, Int, Int)) = tupleLess(a, b) ? (a, b) : (b, a)
        return packCorner(lo) &* 0x9E3779B185EBCA87 &+ packCorner(hi)
    }

    private static func packCorner(_ c: (Int, Int, Int)) -> UInt64 {
        let x = UInt64(UInt32(bitPattern: Int32(c.0)))
        let y = UInt64(UInt32(bitPattern: Int32(c.1)))
        let z = UInt64(UInt32(bitPattern: Int32(c.2)))
        return (x & 0xFFFFF) | ((y & 0xFFFFF) << 20) | ((z & 0xFFFFF) << 40)
    }

    private static func tupleLess(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Bool {
        if a.0 != b.0 { return a.0 < b.0 }
        if a.1 != b.1 { return a.1 < b.1 }
        return a.2 < b.2
    }

    // MARK: - Filename

    private static func sanitize(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }

    // MARK: - Marching cubes lookup tables
    //
    // 256-entry edge table + 256-row triangle table. These are the
    // canonical tables published by Paul Bourke in 1994 and widely used
    // in public-domain implementations.

    private static let edgeTable: [UInt16] = MarchingCubesTables.edges
    private static let triTable: [[Int8]] = MarchingCubesTables.triangles
}

enum MarchingCubesTables {
    /// 256-entry edge bitmask table. Bit *e* of `edges[caseIndex]` is set
    /// when cube edge *e* is intersected by the isosurface for that case.
    static let edges: [UInt16] = [
        0x0,   0x109, 0x203, 0x30A, 0x406, 0x50F, 0x605, 0x70C,
        0x80C, 0x905, 0xA0F, 0xB06, 0xC0A, 0xD03, 0xE09, 0xF00,
        0x190, 0x99,  0x393, 0x29A, 0x596, 0x49F, 0x795, 0x69C,
        0x99C, 0x895, 0xB9F, 0xA96, 0xD9A, 0xC93, 0xF99, 0xE90,
        0x230, 0x339, 0x33,  0x13A, 0x636, 0x73F, 0x435, 0x53C,
        0xA3C, 0xB35, 0x83F, 0x936, 0xE3A, 0xF33, 0xC39, 0xD30,
        0x3A0, 0x2A9, 0x1A3, 0xAA,  0x7A6, 0x6AF, 0x5A5, 0x4AC,
        0xBAC, 0xAA5, 0x9AF, 0x8A6, 0xFAA, 0xEA3, 0xDA9, 0xCA0,
        0x460, 0x569, 0x663, 0x76A, 0x66,  0x16F, 0x265, 0x36C,
        0xC6C, 0xD65, 0xE6F, 0xF66, 0x86A, 0x963, 0xA69, 0xB60,
        0x5F0, 0x4F9, 0x7F3, 0x6FA, 0x1F6, 0xFF,  0x3F5, 0x2FC,
        0xDFC, 0xCF5, 0xFFF, 0xEF6, 0x9FA, 0x8F3, 0xBF9, 0xAF0,
        0x650, 0x759, 0x453, 0x55A, 0x256, 0x35F, 0x55,  0x15C,
        0xE5C, 0xF55, 0xC5F, 0xD56, 0xA5A, 0xB53, 0x859, 0x950,
        0x7C0, 0x6C9, 0x5C3, 0x4CA, 0x3C6, 0x2CF, 0x1C5, 0xCC,
        0xFCC, 0xEC5, 0xDCF, 0xCC6, 0xBCA, 0xAC3, 0x9C9, 0x8C0,
        0x8C0, 0x9C9, 0xAC3, 0xBCA, 0xCC6, 0xDCF, 0xEC5, 0xFCC,
        0xCC,  0x1C5, 0x2CF, 0x3C6, 0x4CA, 0x5C3, 0x6C9, 0x7C0,
        0x950, 0x859, 0xB53, 0xA5A, 0xD56, 0xC5F, 0xF55, 0xE5C,
        0x15C, 0x55,  0x35F, 0x256, 0x55A, 0x453, 0x759, 0x650,
        0xAF0, 0xBF9, 0x8F3, 0x9FA, 0xEF6, 0xFFF, 0xCF5, 0xDFC,
        0x2FC, 0x3F5, 0xFF,  0x1F6, 0x6FA, 0x7F3, 0x4F9, 0x5F0,
        0xB60, 0xA69, 0x963, 0x86A, 0xF66, 0xE6F, 0xD65, 0xC6C,
        0x36C, 0x265, 0x16F, 0x66,  0x76A, 0x663, 0x569, 0x460,
        0xCA0, 0xDA9, 0xEA3, 0xFAA, 0x8A6, 0x9AF, 0xAA5, 0xBAC,
        0x4AC, 0x5A5, 0x6AF, 0x7A6, 0xAA,  0x1A3, 0x2A9, 0x3A0,
        0xD30, 0xC39, 0xF33, 0xE3A, 0x936, 0x83F, 0xB35, 0xA3C,
        0x53C, 0x435, 0x73F, 0x636, 0x13A, 0x33,  0x339, 0x230,
        0xE90, 0xF99, 0xC93, 0xD9A, 0xA96, 0xB9F, 0x895, 0x99C,
        0x69C, 0x795, 0x49F, 0x596, 0x29A, 0x393, 0x99,  0x190,
        0xF00, 0xE09, 0xD03, 0xC0A, 0xB06, 0xA0F, 0x905, 0x80C,
        0x70C, 0x605, 0x50F, 0x406, 0x30A, 0x203, 0x109, 0x0
    ]

    /// 256-row triangle table. Each row lists up to 15 edge indices in
    /// triples, terminated by -1.
    static let triangles: [[Int8]] = rawTriangles
}

// Triangle table is declared outside the MarchingCubesMeshExporter enum to
// keep source-file line-count manageable — it's a 256×16 block.
private let rawTriangles: [[Int8]] = [
    [-1],
    [0, 8, 3, -1],
    [0, 1, 9, -1],
    [1, 8, 3, 9, 8, 1, -1],
    [1, 2, 10, -1],
    [0, 8, 3, 1, 2, 10, -1],
    [9, 2, 10, 0, 2, 9, -1],
    [2, 8, 3, 2, 10, 8, 10, 9, 8, -1],
    [3, 11, 2, -1],
    [0, 11, 2, 8, 11, 0, -1],
    [1, 9, 0, 2, 3, 11, -1],
    [1, 11, 2, 1, 9, 11, 9, 8, 11, -1],
    [3, 10, 1, 11, 10, 3, -1],
    [0, 10, 1, 0, 8, 10, 8, 11, 10, -1],
    [3, 9, 0, 3, 11, 9, 11, 10, 9, -1],
    [9, 8, 10, 10, 8, 11, -1],
    [4, 7, 8, -1],
    [4, 3, 0, 7, 3, 4, -1],
    [0, 1, 9, 8, 4, 7, -1],
    [4, 1, 9, 4, 7, 1, 7, 3, 1, -1],
    [1, 2, 10, 8, 4, 7, -1],
    [3, 4, 7, 3, 0, 4, 1, 2, 10, -1],
    [9, 2, 10, 9, 0, 2, 8, 4, 7, -1],
    [2, 10, 9, 2, 9, 7, 2, 7, 3, 7, 9, 4, -1],
    [8, 4, 7, 3, 11, 2, -1],
    [11, 4, 7, 11, 2, 4, 2, 0, 4, -1],
    [9, 0, 1, 8, 4, 7, 2, 3, 11, -1],
    [4, 7, 11, 9, 4, 11, 9, 11, 2, 9, 2, 1, -1],
    [3, 10, 1, 3, 11, 10, 7, 8, 4, -1],
    [1, 11, 10, 1, 4, 11, 1, 0, 4, 7, 11, 4, -1],
    [4, 7, 8, 9, 0, 11, 9, 11, 10, 11, 0, 3, -1],
    [4, 7, 11, 4, 11, 9, 9, 11, 10, -1],
    [9, 5, 4, -1],
    [9, 5, 4, 0, 8, 3, -1],
    [0, 5, 4, 1, 5, 0, -1],
    [8, 5, 4, 8, 3, 5, 3, 1, 5, -1],
    [1, 2, 10, 9, 5, 4, -1],
    [3, 0, 8, 1, 2, 10, 4, 9, 5, -1],
    [5, 2, 10, 5, 4, 2, 4, 0, 2, -1],
    [2, 10, 5, 3, 2, 5, 3, 5, 4, 3, 4, 8, -1],
    [9, 5, 4, 2, 3, 11, -1],
    [0, 11, 2, 0, 8, 11, 4, 9, 5, -1],
    [0, 5, 4, 0, 1, 5, 2, 3, 11, -1],
    [2, 1, 5, 2, 5, 8, 2, 8, 11, 4, 8, 5, -1],
    [10, 3, 11, 10, 1, 3, 9, 5, 4, -1],
    [4, 9, 5, 0, 8, 1, 8, 10, 1, 8, 11, 10, -1],
    [5, 4, 0, 5, 0, 11, 5, 11, 10, 11, 0, 3, -1],
    [5, 4, 8, 5, 8, 10, 10, 8, 11, -1],
    [9, 7, 8, 5, 7, 9, -1],
    [9, 3, 0, 9, 5, 3, 5, 7, 3, -1],
    [0, 7, 8, 0, 1, 7, 1, 5, 7, -1],
    [1, 5, 3, 3, 5, 7, -1],
    [9, 7, 8, 9, 5, 7, 10, 1, 2, -1],
    [10, 1, 2, 9, 5, 0, 5, 3, 0, 5, 7, 3, -1],
    [8, 0, 2, 8, 2, 5, 8, 5, 7, 10, 5, 2, -1],
    [2, 10, 5, 2, 5, 3, 3, 5, 7, -1],
    [7, 9, 5, 7, 8, 9, 3, 11, 2, -1],
    [9, 5, 7, 9, 7, 2, 9, 2, 0, 2, 7, 11, -1],
    [2, 3, 11, 0, 1, 8, 1, 7, 8, 1, 5, 7, -1],
    [11, 2, 1, 11, 1, 7, 7, 1, 5, -1],
    [9, 5, 8, 8, 5, 7, 10, 1, 3, 10, 3, 11, -1],
    [5, 7, 0, 5, 0, 9, 7, 11, 0, 1, 0, 10, 11, 10, 0, -1],
    [11, 10, 0, 11, 0, 3, 10, 5, 0, 8, 0, 7, 5, 7, 0, -1],
    [11, 10, 5, 7, 11, 5, -1],
    [10, 6, 5, -1],
    [0, 8, 3, 5, 10, 6, -1],
    [9, 0, 1, 5, 10, 6, -1],
    [1, 8, 3, 1, 9, 8, 5, 10, 6, -1],
    [1, 6, 5, 2, 6, 1, -1],
    [1, 6, 5, 1, 2, 6, 3, 0, 8, -1],
    [9, 6, 5, 9, 0, 6, 0, 2, 6, -1],
    [5, 9, 8, 5, 8, 2, 5, 2, 6, 3, 2, 8, -1],
    [2, 3, 11, 10, 6, 5, -1],
    [11, 0, 8, 11, 2, 0, 10, 6, 5, -1],
    [0, 1, 9, 2, 3, 11, 5, 10, 6, -1],
    [5, 10, 6, 1, 9, 2, 9, 11, 2, 9, 8, 11, -1],
    [6, 3, 11, 6, 5, 3, 5, 1, 3, -1],
    [0, 8, 11, 0, 11, 5, 0, 5, 1, 5, 11, 6, -1],
    [3, 11, 6, 0, 3, 6, 0, 6, 5, 0, 5, 9, -1],
    [6, 5, 9, 6, 9, 11, 11, 9, 8, -1],
    [5, 10, 6, 4, 7, 8, -1],
    [4, 3, 0, 4, 7, 3, 6, 5, 10, -1],
    [1, 9, 0, 5, 10, 6, 8, 4, 7, -1],
    [10, 6, 5, 1, 9, 7, 1, 7, 3, 7, 9, 4, -1],
    [6, 1, 2, 6, 5, 1, 4, 7, 8, -1],
    [1, 2, 5, 5, 2, 6, 3, 0, 4, 3, 4, 7, -1],
    [8, 4, 7, 9, 0, 5, 0, 6, 5, 0, 2, 6, -1],
    [7, 3, 9, 7, 9, 4, 3, 2, 9, 5, 9, 6, 2, 6, 9, -1],
    [3, 11, 2, 7, 8, 4, 10, 6, 5, -1],
    [5, 10, 6, 4, 7, 2, 4, 2, 0, 2, 7, 11, -1],
    [0, 1, 9, 4, 7, 8, 2, 3, 11, 5, 10, 6, -1],
    [9, 2, 1, 9, 11, 2, 9, 4, 11, 7, 11, 4, 5, 10, 6, -1],
    [8, 4, 7, 3, 11, 5, 3, 5, 1, 5, 11, 6, -1],
    [5, 1, 11, 5, 11, 6, 1, 0, 11, 7, 11, 4, 0, 4, 11, -1],
    [0, 5, 9, 0, 6, 5, 0, 3, 6, 11, 6, 3, 8, 4, 7, -1],
    [6, 5, 9, 6, 9, 11, 4, 7, 9, 7, 11, 9, -1],
    [10, 4, 9, 6, 4, 10, -1],
    [4, 10, 6, 4, 9, 10, 0, 8, 3, -1],
    [10, 0, 1, 10, 6, 0, 6, 4, 0, -1],
    [8, 3, 1, 8, 1, 6, 8, 6, 4, 6, 1, 10, -1],
    [1, 4, 9, 1, 2, 4, 2, 6, 4, -1],
    [3, 0, 8, 1, 2, 9, 2, 4, 9, 2, 6, 4, -1],
    [0, 2, 4, 4, 2, 6, -1],
    [8, 3, 2, 8, 2, 4, 4, 2, 6, -1],
    [10, 4, 9, 10, 6, 4, 11, 2, 3, -1],
    [0, 8, 2, 2, 8, 11, 4, 9, 10, 4, 10, 6, -1],
    [3, 11, 2, 0, 1, 6, 0, 6, 4, 6, 1, 10, -1],
    [6, 4, 1, 6, 1, 10, 4, 8, 1, 2, 1, 11, 8, 11, 1, -1],
    [9, 6, 4, 9, 3, 6, 9, 1, 3, 11, 6, 3, -1],
    [8, 11, 1, 8, 1, 0, 11, 6, 1, 9, 1, 4, 6, 4, 1, -1],
    [3, 11, 6, 3, 6, 0, 0, 6, 4, -1],
    [6, 4, 8, 11, 6, 8, -1],
    [7, 10, 6, 7, 8, 10, 8, 9, 10, -1],
    [0, 7, 3, 0, 10, 7, 0, 9, 10, 6, 7, 10, -1],
    [10, 6, 7, 1, 10, 7, 1, 7, 8, 1, 8, 0, -1],
    [10, 6, 7, 10, 7, 1, 1, 7, 3, -1],
    [1, 2, 6, 1, 6, 8, 1, 8, 9, 8, 6, 7, -1],
    [2, 6, 9, 2, 9, 1, 6, 7, 9, 0, 9, 3, 7, 3, 9, -1],
    [7, 8, 0, 7, 0, 6, 6, 0, 2, -1],
    [7, 3, 2, 6, 7, 2, -1],
    [2, 3, 11, 10, 6, 8, 10, 8, 9, 8, 6, 7, -1],
    [2, 0, 7, 2, 7, 11, 0, 9, 7, 6, 7, 10, 9, 10, 7, -1],
    [1, 8, 0, 1, 7, 8, 1, 10, 7, 6, 7, 10, 2, 3, 11, -1],
    [11, 2, 1, 11, 1, 7, 10, 6, 1, 6, 7, 1, -1],
    [8, 9, 6, 8, 6, 7, 9, 1, 6, 11, 6, 3, 1, 3, 6, -1],
    [0, 9, 1, 11, 6, 7, -1],
    [7, 8, 0, 7, 0, 6, 3, 11, 0, 11, 6, 0, -1],
    [7, 11, 6, -1],
    [7, 6, 11, -1],
    [3, 0, 8, 11, 7, 6, -1],
    [0, 1, 9, 11, 7, 6, -1],
    [8, 1, 9, 8, 3, 1, 11, 7, 6, -1],
    [10, 1, 2, 6, 11, 7, -1],
    [1, 2, 10, 3, 0, 8, 6, 11, 7, -1],
    [2, 9, 0, 2, 10, 9, 6, 11, 7, -1],
    [6, 11, 7, 2, 10, 3, 10, 8, 3, 10, 9, 8, -1],
    [7, 2, 3, 6, 2, 7, -1],
    [7, 0, 8, 7, 6, 0, 6, 2, 0, -1],
    [2, 7, 6, 2, 3, 7, 0, 1, 9, -1],
    [1, 6, 2, 1, 8, 6, 1, 9, 8, 8, 7, 6, -1],
    [10, 7, 6, 10, 1, 7, 1, 3, 7, -1],
    [10, 7, 6, 1, 7, 10, 1, 8, 7, 1, 0, 8, -1],
    [0, 3, 7, 0, 7, 10, 0, 10, 9, 6, 10, 7, -1],
    [7, 6, 10, 7, 10, 8, 8, 10, 9, -1],
    [6, 8, 4, 11, 8, 6, -1],
    [3, 6, 11, 3, 0, 6, 0, 4, 6, -1],
    [8, 6, 11, 8, 4, 6, 9, 0, 1, -1],
    [9, 4, 6, 9, 6, 3, 9, 3, 1, 11, 3, 6, -1],
    [6, 8, 4, 6, 11, 8, 2, 10, 1, -1],
    [1, 2, 10, 3, 0, 11, 0, 6, 11, 0, 4, 6, -1],
    [4, 11, 8, 4, 6, 11, 0, 2, 9, 2, 10, 9, -1],
    [10, 9, 3, 10, 3, 2, 9, 4, 3, 11, 3, 6, 4, 6, 3, -1],
    [8, 2, 3, 8, 4, 2, 4, 6, 2, -1],
    [0, 4, 2, 4, 6, 2, -1],
    [1, 9, 0, 2, 3, 4, 2, 4, 6, 4, 3, 8, -1],
    [1, 9, 4, 1, 4, 2, 2, 4, 6, -1],
    [8, 1, 3, 8, 6, 1, 8, 4, 6, 6, 10, 1, -1],
    [10, 1, 0, 10, 0, 6, 6, 0, 4, -1],
    [4, 6, 3, 4, 3, 8, 6, 10, 3, 0, 3, 9, 10, 9, 3, -1],
    [10, 9, 4, 6, 10, 4, -1],
    [4, 9, 5, 7, 6, 11, -1],
    [0, 8, 3, 4, 9, 5, 11, 7, 6, -1],
    [5, 0, 1, 5, 4, 0, 7, 6, 11, -1],
    [11, 7, 6, 8, 3, 4, 3, 5, 4, 3, 1, 5, -1],
    [9, 5, 4, 10, 1, 2, 7, 6, 11, -1],
    [6, 11, 7, 1, 2, 10, 0, 8, 3, 4, 9, 5, -1],
    [7, 6, 11, 5, 4, 10, 4, 2, 10, 4, 0, 2, -1],
    [3, 4, 8, 3, 5, 4, 3, 2, 5, 10, 5, 2, 11, 7, 6, -1],
    [7, 2, 3, 7, 6, 2, 5, 4, 9, -1],
    [9, 5, 4, 0, 8, 6, 0, 6, 2, 6, 8, 7, -1],
    [3, 6, 2, 3, 7, 6, 1, 5, 0, 5, 4, 0, -1],
    [6, 2, 8, 6, 8, 7, 2, 1, 8, 4, 8, 5, 1, 5, 8, -1],
    [9, 5, 4, 10, 1, 6, 1, 7, 6, 1, 3, 7, -1],
    [1, 6, 10, 1, 7, 6, 1, 0, 7, 8, 7, 0, 9, 5, 4, -1],
    [4, 0, 10, 4, 10, 5, 0, 3, 10, 6, 10, 7, 3, 7, 10, -1],
    [7, 6, 10, 7, 10, 8, 5, 4, 10, 4, 8, 10, -1],
    [6, 9, 5, 6, 11, 9, 11, 8, 9, -1],
    [3, 6, 11, 0, 6, 3, 0, 5, 6, 0, 9, 5, -1],
    [0, 11, 8, 0, 5, 11, 0, 1, 5, 5, 6, 11, -1],
    [6, 11, 3, 6, 3, 5, 5, 3, 1, -1],
    [1, 2, 10, 9, 5, 11, 9, 11, 8, 11, 5, 6, -1],
    [0, 11, 3, 0, 6, 11, 0, 9, 6, 5, 6, 9, 1, 2, 10, -1],
    [11, 8, 5, 11, 5, 6, 8, 0, 5, 10, 5, 2, 0, 2, 5, -1],
    [6, 11, 3, 6, 3, 5, 2, 10, 3, 10, 5, 3, -1],
    [5, 8, 9, 5, 2, 8, 5, 6, 2, 3, 8, 2, -1],
    [9, 5, 6, 9, 6, 0, 0, 6, 2, -1],
    [1, 5, 8, 1, 8, 0, 5, 6, 8, 3, 8, 2, 6, 2, 8, -1],
    [1, 5, 6, 2, 1, 6, -1],
    [1, 3, 6, 1, 6, 10, 3, 8, 6, 5, 6, 9, 8, 9, 6, -1],
    [10, 1, 0, 10, 0, 6, 9, 5, 0, 5, 6, 0, -1],
    [0, 3, 8, 5, 6, 10, -1],
    [10, 5, 6, -1],
    [11, 5, 10, 7, 5, 11, -1],
    [11, 5, 10, 11, 7, 5, 8, 3, 0, -1],
    [5, 11, 7, 5, 10, 11, 1, 9, 0, -1],
    [10, 7, 5, 10, 11, 7, 9, 8, 1, 8, 3, 1, -1],
    [11, 1, 2, 11, 7, 1, 7, 5, 1, -1],
    [0, 8, 3, 1, 2, 7, 1, 7, 5, 7, 2, 11, -1],
    [9, 7, 5, 9, 2, 7, 9, 0, 2, 2, 11, 7, -1],
    [7, 5, 2, 7, 2, 11, 5, 9, 2, 3, 2, 8, 9, 8, 2, -1],
    [2, 5, 10, 2, 3, 5, 3, 7, 5, -1],
    [8, 2, 0, 8, 5, 2, 8, 7, 5, 10, 2, 5, -1],
    [9, 0, 1, 5, 10, 3, 5, 3, 7, 3, 10, 2, -1],
    [9, 8, 2, 9, 2, 1, 8, 7, 2, 10, 2, 5, 7, 5, 2, -1],
    [1, 3, 5, 3, 7, 5, -1],
    [0, 8, 7, 0, 7, 1, 1, 7, 5, -1],
    [9, 0, 3, 9, 3, 5, 5, 3, 7, -1],
    [9, 8, 7, 5, 9, 7, -1],
    [5, 8, 4, 5, 10, 8, 10, 11, 8, -1],
    [5, 0, 4, 5, 11, 0, 5, 10, 11, 11, 3, 0, -1],
    [0, 1, 9, 8, 4, 10, 8, 10, 11, 10, 4, 5, -1],
    [10, 11, 4, 10, 4, 5, 11, 3, 4, 9, 4, 1, 3, 1, 4, -1],
    [2, 5, 1, 2, 8, 5, 2, 11, 8, 4, 5, 8, -1],
    [0, 4, 11, 0, 11, 3, 4, 5, 11, 2, 11, 1, 5, 1, 11, -1],
    [0, 2, 5, 0, 5, 9, 2, 11, 5, 4, 5, 8, 11, 8, 5, -1],
    [9, 4, 5, 2, 11, 3, -1],
    [2, 5, 10, 3, 5, 2, 3, 4, 5, 3, 8, 4, -1],
    [5, 10, 2, 5, 2, 4, 4, 2, 0, -1],
    [3, 10, 2, 3, 5, 10, 3, 8, 5, 4, 5, 8, 0, 1, 9, -1],
    [5, 10, 2, 5, 2, 4, 1, 9, 2, 9, 4, 2, -1],
    [8, 4, 5, 8, 5, 3, 3, 5, 1, -1],
    [0, 4, 5, 1, 0, 5, -1],
    [8, 4, 5, 8, 5, 3, 9, 0, 5, 0, 3, 5, -1],
    [9, 4, 5, -1],
    [4, 11, 7, 4, 9, 11, 9, 10, 11, -1],
    [0, 8, 3, 4, 9, 7, 9, 11, 7, 9, 10, 11, -1],
    [1, 10, 11, 1, 11, 4, 1, 4, 0, 7, 4, 11, -1],
    [3, 1, 4, 3, 4, 8, 1, 10, 4, 7, 4, 11, 10, 11, 4, -1],
    [4, 11, 7, 9, 11, 4, 9, 2, 11, 9, 1, 2, -1],
    [9, 7, 4, 9, 11, 7, 9, 1, 11, 2, 11, 1, 0, 8, 3, -1],
    [11, 7, 4, 11, 4, 2, 2, 4, 0, -1],
    [11, 7, 4, 11, 4, 2, 8, 3, 4, 3, 2, 4, -1],
    [2, 9, 10, 2, 7, 9, 2, 3, 7, 7, 4, 9, -1],
    [9, 10, 7, 9, 7, 4, 10, 2, 7, 8, 7, 0, 2, 0, 7, -1],
    [3, 7, 10, 3, 10, 2, 7, 4, 10, 1, 10, 0, 4, 0, 10, -1],
    [1, 10, 2, 8, 7, 4, -1],
    [4, 9, 1, 4, 1, 7, 7, 1, 3, -1],
    [4, 9, 1, 4, 1, 7, 0, 8, 1, 8, 7, 1, -1],
    [4, 0, 3, 7, 4, 3, -1],
    [4, 8, 7, -1],
    [9, 10, 8, 10, 11, 8, -1],
    [3, 0, 9, 3, 9, 11, 11, 9, 10, -1],
    [0, 1, 10, 0, 10, 8, 8, 10, 11, -1],
    [3, 1, 10, 11, 3, 10, -1],
    [1, 2, 11, 1, 11, 9, 9, 11, 8, -1],
    [3, 0, 9, 3, 9, 11, 1, 2, 9, 2, 11, 9, -1],
    [0, 2, 11, 8, 0, 11, -1],
    [3, 2, 11, -1],
    [2, 3, 8, 2, 8, 10, 10, 8, 9, -1],
    [9, 10, 2, 0, 9, 2, -1],
    [2, 3, 8, 2, 8, 10, 0, 1, 8, 1, 10, 8, -1],
    [1, 10, 2, -1],
    [1, 3, 8, 9, 1, 8, -1],
    [0, 9, 1, -1],
    [0, 3, 8, -1],
    [-1]
]
