//
//  DeleteFaceKit.swift
//  openshape3d
//
//  Delete Face (spec §4.16) — the direct-modeling gesture that removes a face
//  and lets the neighbouring surfaces extend to re-close the solid, so a hole
//  or a pocket can be deleted without unwinding the history that made it.
//
//  This kit is the pure half: it turns a PICKED face into the two things the
//  rest of the system needs, and nothing else.
//
//    1. A `samplePoint` — a body-local point lying ON that face, which is how
//       OCCT is told which face to remove. Never a centroid-of-triangles: for
//       a cylinder that lands on the AXIS, inside the solid, and OCCT would
//       either remove nothing or remove the wrong face.
//    2. A `FaceSignature`, minted by `SignatureNaming`'s own builders rather
//       than re-derived here, so the `FaceRef` recorded for the feature node
//       matches what a rebuild will enumerate.
//
//  The healing itself is `OCCTKernel.removingFaces`; the parametric replay is
//  `FeatureGraph.evalDeleteFace`. Both already existed — this is what lets a
//  live pick reach them.
//

import Foundation
import simd

nonisolated enum DeleteFaceKit {

    /// A face picked for deletion, reduced to what the kernel and the feature
    /// graph each need. `triangles` is kept for the on-screen highlight and to
    /// recognise a second tap on the same face as "unpick me".
    nonisolated struct Target: Equatable, Sendable {
        var triangles: [Int]
        /// Body-LOCAL, and ON the surface. Body-local because `Body.brep` is:
        /// handing OCCT a world point for a moved body would miss.
        var samplePoint: SIMD3<Double>
        var signature: FaceSignature

        /// Two picks are the same face when they cover the same triangles —
        /// the same test the shell pick uses.
        static func == (lhs: Target, rhs: Target) -> Bool {
            Set(lhs.triangles) == Set(rhs.triangles)
        }
    }

    /// A planar face. The sample point is the outline centroid, which is
    /// interior for the convex outlines the picker produces.
    static func target(planar face: PlanarFace) -> Target? {
        guard !face.triangles.isEmpty, !face.outline.isEmpty else { return nil }
        let c = face.outline.reduce(SIMD2<Double>.zero, +) / Double(face.outline.count)
        return Target(
            triangles: face.triangles,
            samplePoint: face.origin + face.basisX * c.x + face.basisY * c.y,
            signature: SignatureNaming.signature(planar: face))
    }

    /// A cylindrical face — the wall of a hole or a cylindrical fillet corner.
    /// The sample point steps OUT from the axis at mid-height, so it lands on
    /// the surface instead of inside the solid.
    static func target(cylindrical cyl: CylindricalFace) -> Target? {
        guard !cyl.triangles.isEmpty, cyl.radius > 1e-9 else { return nil }
        let axis = simd_normalize(cyl.axisDir)
        // Any unit vector perpendicular to the axis reaches the surface on a
        // full 360° cylinder.
        let seed = abs(axis.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
        let radial = simd_normalize(simd_cross(axis, seed))
        let mid = (cyl.minT + cyl.maxT) / 2
        // `axisPoint` sits at an arbitrary axial position; re-anchor it to the
        // mid-height plane before stepping outward.
        let onAxis = cyl.axisPoint + axis * (mid - simd_dot(cyl.axisPoint, axis))
        return Target(
            triangles: cyl.triangles,
            samplePoint: onAxis + radial * cyl.radius,
            signature: SignatureNaming.signature(cylinder: cyl))
    }

    /// A cylindrical face backed by `mesh` — works for BOTH 360° holes/bosses
    /// AND partial cylinders (such as 90° quarter-cylinder fillets in any
    /// quadrant), because the radial direction is taken from an actual
    /// triangle of `cyl.triangles` instead of an arbitrary `cross(axis, seed)`.
    static func target(cylindrical cyl: CylindricalFace, in mesh: RenderMesh) -> Target? {
        guard !cyl.triangles.isEmpty, cyl.radius > 1e-9 else { return nil }
        let axis = simd_normalize(cyl.axisDir)
        let mid = (cyl.minT + cyl.maxT) / 2
        let onAxis = cyl.axisPoint + axis * (mid - simd_dot(cyl.axisPoint, axis))

        // Pick the triangle in `cyl.triangles` whose centroid is closest to
        // the axial midpoint `mid` and project its radial vector onto the
        // cylinder surface so the sample point is guaranteed to lie inside the
        // trimmed B-Rep face (essential for 90° fillets in all 4 quadrants).
        var bestRadial: SIMD3<Double>?
        var bestAxialDist = Double.infinity
        for t in cyl.triangles where t >= 0 && t < mesh.triangleCount {
            let a = mesh.positions[Int(mesh.indices[t * 3])]
            let b = mesh.positions[Int(mesh.indices[t * 3 + 1])]
            let c = mesh.positions[Int(mesh.indices[t * 3 + 2])]
            let center = SIMD3<Double>(
                Double(a.x + b.x + c.x) / 3.0,
                Double(a.y + b.y + c.y) / 3.0,
                Double(a.z + b.z + c.z) / 3.0
            )
            let axialPos = simd_dot(center, axis)
            let d = center - (cyl.axisPoint + axis * (axialPos - simd_dot(cyl.axisPoint, axis)))
            let perp = d - axis * simd_dot(d, axis)
            let len = simd_length(perp)
            guard len > 1e-9 else { continue }
            let axialDist = abs(axialPos - mid)
            if axialDist < bestAxialDist {
                bestAxialDist = axialDist
                bestRadial = perp / len
            }
        }

        if let radial = bestRadial {
            return Target(
                triangles: cyl.triangles,
                samplePoint: onAxis + radial * cyl.radius,
                signature: SignatureNaming.signature(cylinder: cyl))
        }
        return target(cylindrical: cyl)
    }

    /// The face under a tap: a cylindrical wall/fillet wins over the coplanar
    /// sliver `planarFace` would return for it, followed by planar faces, and
    /// finally general curved B-Rep faces (such as 3-edge spherical fillet
    /// corner patches, toroidal fillets, or conical chamfers).
    static func target(in mesh: RenderMesh, seedTriangle: Int) -> Target? {
        if let cyl = FaceTopology.cylindricalFace(in: mesh, seedTriangle: seedTriangle),
           let target = target(cylindrical: cyl, in: mesh) {
            return target
        }
        if let planar = FaceTopology.planarFace(in: mesh, seedTriangle: seedTriangle),
           !planar.triangles.isEmpty,
           let target = target(planar: planar) {
            if planar.triangles.count >= 2 || mesh.validFaceRegions != nil {
                return target
            }
        }
        if let smooth = FaceTopology.smoothRegion(in: mesh, seedTriangle: seedTriangle),
           smooth.isCurved || (mesh.validFaceRegions != nil && !smooth.triangles.isEmpty),
           seedTriangle >= 0, seedTriangle < mesh.triangleCount {
            let a = mesh.positions[Int(mesh.indices[seedTriangle * 3])]
            let b = mesh.positions[Int(mesh.indices[seedTriangle * 3 + 1])]
            let c = mesh.positions[Int(mesh.indices[seedTriangle * 3 + 2])]
            let samplePt = SIMD3<Double>(
                Double(a.x + b.x + c.x) / 3.0,
                Double(a.y + b.y + c.y) / 3.0,
                Double(a.z + b.z + c.z) / 3.0
            )
            var totalArea = 0.0
            var weightedCentroid = SIMD3<Double>.zero
            var normalSum = SIMD3<Double>.zero
            for t in smooth.triangles where t >= 0 && t < mesh.triangleCount {
                let p0 = mesh.positions[Int(mesh.indices[t * 3])]
                let p1 = mesh.positions[Int(mesh.indices[t * 3 + 1])]
                let p2 = mesh.positions[Int(mesh.indices[t * 3 + 2])]
                let d0 = SIMD3<Double>(Double(p0.x), Double(p0.y), Double(p0.z))
                let d1 = SIMD3<Double>(Double(p1.x), Double(p1.y), Double(p1.z))
                let d2 = SIMD3<Double>(Double(p2.x), Double(p2.y), Double(p2.z))
                let cross = simd_cross(d1 - d0, d2 - d0)
                let area = simd_length(cross) * 0.5
                totalArea += area
                weightedCentroid += ((d0 + d1 + d2) / 3.0) * area
                normalSum += cross
            }
            let centroid = totalArea > 1e-12 ? (weightedCentroid / totalArea) : samplePt
            let nLen = simd_length(normalSum)
            let n = nLen > 1e-12 ? (normalSum / nLen) : SIMD3<Double>(0, 1, 0)
            let sig = FaceSignature(
                kind: .cylindrical(radius: max(sqrt(totalArea / Double.pi), 1e-3)),
                normal: n,
                centroid: centroid,
                area: totalArea,
                planeOffset: simd_dot(n, centroid)
            )
            return Target(triangles: smooth.triangles, samplePoint: samplePt, signature: sig)
        }
        if let planar = FaceTopology.planarFace(in: mesh, seedTriangle: seedTriangle) {
            return target(planar: planar)
        }
        return nil
    }

}
