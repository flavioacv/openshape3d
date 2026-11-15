//
//  PrintExportKit.swift
//  openshape3d
//
//  High-precision B-rep tessellation and printability validation for 3D
//  printing (STL / 3MF). Uses exact OCCT B-rep geometry when available so
//  curved surfaces and fillets print smoothly without bloating viewport meshes.
//

import Foundation
import simd

nonisolated enum PrintMeshResolution: String, CaseIterable, Sendable {
    case draft
    case standard
    case fine
    case ultra

    var linearDeflection: Double {
        switch self {
        case .draft: return 0.1
        case .standard: return 0.04
        case .fine: return 0.015
        case .ultra: return 0.006
        }
    }

    var angularDeflection: Double {
        switch self {
        case .draft: return 0.2618     // ~15 deg
        case .standard: return 0.1396  // ~8 deg
        case .fine: return 0.0873      // ~5 deg
        case .ultra: return 0.0524     // ~3 deg
        }
    }
}

nonisolated struct PrintBodyReport: Sendable, Equatable {
    let bodyID: BodyID
    let name: String
    let isWatertight: Bool
    let openFreeWires: Int
    let nonManifoldEdges: Int
    let openMeshEdges: Int
    let volumeMM3: Double
    let boundsMinMM: SIMD3<Double>
    let boundsMaxMM: SIMD3<Double>

    var dimensionsMM: SIMD3<Double> {
        boundsMaxMM - boundsMinMM
    }
}

nonisolated struct PrintabilityReport: Sendable, Equatable {
    let bodies: [PrintBodyReport]

    var isPrintable: Bool {
        !bodies.isEmpty && bodies.allSatisfy {
            $0.isWatertight && $0.openFreeWires == 0 && $0.nonManifoldEdges == 0 && $0.openMeshEdges == 0 && $0.volumeMM3 > 0
        }
    }

    var totalVolumeCM3: Double {
        bodies.reduce(0.0) { $0 + max(0.0, $1.volumeMM3) } / 1000.0
    }
}

nonisolated enum PrintExportKit {

    struct WorldMesh: Sendable {
        let positions: [SIMD3<Float>]
        let indices: [UInt32]
    }

    /// Generate a world-space triangle mesh for 3D printing from the body's
    /// exact OCCT B-rep at `resolution`, falling back to `body.render` if the
    /// body has no B-rep handle.
    static func worldMesh(for body: Body, resolution: PrintMeshResolution = .standard) -> WorldMesh {
        let sourcePositions: [SIMD3<Float>]
        let sourceIndices: [UInt32]

        if let brep = body.brep {
            let m = OCCTKernel.renderMesh(
                from: brep,
                angularDeflection: resolution.angularDeflection,
                linearDeflection: resolution.linearDeflection
            )
            if !m.positions.isEmpty && !m.indices.isEmpty {
                sourcePositions = m.positions
                sourceIndices = m.indices
            } else {
                sourcePositions = body.render.positions
                sourceIndices = body.render.indices
            }
        } else {
            sourcePositions = body.render.positions
            sourceIndices = body.render.indices
        }

        let transform = body.transform
        let worldPositions = sourcePositions.map { p in
            SIMD3<Float>(transform.applying(to: SIMD3<Double>(p)))
        }
        return WorldMesh(positions: worldPositions, indices: sourceIndices)
    }

    /// Inspect every body for watertightness, manifold edges, volume, and
    /// millimeter dimensions prior to 3D printing export.
    static func validateForPrint(bodies: [Body], resolution: PrintMeshResolution = .standard) -> PrintabilityReport {
        let reports = bodies.map { body -> PrintBodyReport in
            let mesh = worldMesh(for: body, resolution: resolution)
            let topology = analyzeMeshManifold(positions: mesh.positions, indices: mesh.indices)

            var openFreeWires = 0
            var volumeMM3 = 0.0
            var brepValid = true
            if let brep = body.brep {
                let health = OCCTKernel.healthReport(for: brep, runBOPCheck: false)
                openFreeWires = health.openFreeWires
                volumeMM3 = health.volumeMM3
                brepValid = health.isValid
            } else {
                volumeMM3 = signedMeshVolume(positions: mesh.positions, indices: mesh.indices)
            }

            let bounds = computeBounds(positions: mesh.positions)
            let watertight = brepValid && openFreeWires == 0 && topology.openEdges == 0 && topology.nonManifoldEdges == 0

            return PrintBodyReport(
                bodyID: body.id,
                name: body.name,
                isWatertight: watertight,
                openFreeWires: openFreeWires,
                nonManifoldEdges: topology.nonManifoldEdges,
                openMeshEdges: topology.openEdges,
                volumeMM3: volumeMM3,
                boundsMinMM: bounds.min,
                boundsMaxMM: bounds.max
            )
        }
        return PrintabilityReport(bodies: reports)
    }

    private struct EdgeKey: Hashable {
        let a: Int
        let b: Int
        init(_ i0: Int, _ i1: Int) {
            if i0 < i1 { a = i0; b = i1 } else { a = i1; b = i0 }
        }
    }

    private struct QuantizedPos: Hashable {
        let x: Int64
        let y: Int64
        let z: Int64
        init(_ p: SIMD3<Float>) {
            // 1e-4 mm weld tolerance so split-normal B-rep vertices share edges.
            x = Int64((Double(p.x) * 10_000.0).rounded())
            y = Int64((Double(p.y) * 10_000.0).rounded())
            z = Int64((Double(p.z) * 10_000.0).rounded())
        }
    }

    private static func analyzeMeshManifold(positions: [SIMD3<Float>], indices: [UInt32]) -> (openEdges: Int, nonManifoldEdges: Int) {
        var vertexIDMap: [QuantizedPos: Int] = [:]
        var remapped = [Int](repeating: 0, count: positions.count)
        var nextID = 0
        for (i, p) in positions.enumerated() {
            let key = QuantizedPos(p)
            if let existing = vertexIDMap[key] {
                remapped[i] = existing
            } else {
                vertexIDMap[key] = nextID
                remapped[i] = nextID
                nextID += 1
            }
        }

        var edgeCounts: [EdgeKey: Int] = [:]
        var tri = 0
        while tri + 2 < indices.count {
            let a = remapped[Int(indices[tri])]
            let b = remapped[Int(indices[tri + 1])]
            let c = remapped[Int(indices[tri + 2])]
            if a != b && b != c && c != a {
                edgeCounts[EdgeKey(a, b), default: 0] += 1
                edgeCounts[EdgeKey(b, c), default: 0] += 1
                edgeCounts[EdgeKey(c, a), default: 0] += 1
            }
            tri += 3
        }

        var openEdges = 0
        var nonManifold = 0
        for count in edgeCounts.values {
            if count == 1 { openEdges += 1 }
            else if count > 2 { nonManifold += 1 }
        }
        return (openEdges, nonManifold)
    }

    private static func signedMeshVolume(positions: [SIMD3<Float>], indices: [UInt32]) -> Double {
        var total = 0.0
        var i = 0
        while i + 2 < indices.count {
            let a = SIMD3<Double>(positions[Int(indices[i])])
            let b = SIMD3<Double>(positions[Int(indices[i + 1])])
            let c = SIMD3<Double>(positions[Int(indices[i + 2])])
            total += simd_dot(a, simd_cross(b, c)) / 6.0
            i += 3
        }
        return abs(total)
    }

    private static func computeBounds(positions: [SIMD3<Float>]) -> (min: SIMD3<Double>, max: SIMD3<Double>) {
        guard !positions.isEmpty else { return (.zero, .zero) }
        var lo = SIMD3<Double>(repeating: .infinity)
        var hi = SIMD3<Double>(repeating: -.infinity)
        for p in positions {
            let d = SIMD3<Double>(p)
            lo = simd_min(lo, d)
            hi = simd_max(hi, d)
        }
        return (lo, hi)
    }
}
