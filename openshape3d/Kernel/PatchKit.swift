//
//  PatchKit.swift
//  openshape3d
//
//  Spec §4.18 / Shapr3D Tools.SolidPatch:
//  Creates a watertight planar or fitted patch face over an open loop of boundary edges.
//

import Foundation
import simd
import Euclid

nonisolated enum PatchKit {

    /// Creates a patch face (as a Euclid mesh) across an ordered 3D boundary loop.
    /// Returns nil when the loop has fewer than 3 vertices.
    static func patch(loop: [SIMD3<Double>]) -> Euclid.Mesh? {
        guard loop.count >= 3 else { return nil }

        // Compute centroid
        var centroid = SIMD3<Double>.zero
        for p in loop { centroid += p }
        centroid /= Double(loop.count)

        // Compute Newell's method normal for the 3D polygon loop
        var normal = SIMD3<Double>.zero
        for i in 0..<loop.count {
            let curr = loop[i]
            let next = loop[(i + 1) % loop.count]
            normal.x += (curr.y - next.y) * (curr.z + next.z)
            normal.y += (curr.z - next.z) * (curr.x + next.x)
            normal.z += (curr.x - next.x) * (curr.y + next.y)
        }
        let len = simd_length(normal)
        guard len > 1e-9 else { return nil }
        normal /= len

        // Build vertices for Euclid.Polygon
        let vertices = loop.map { p in
            Vertex(Vector(p.x, p.y, p.z), Vector(normal.x, normal.y, normal.z))
        }

        // Polygon handles triangulation internally
        let poly1 = Euclid.Polygon(vertices)
        let poly2 = Euclid.Polygon(vertices.reversed()) // Double-sided so boolean/union bonds cleanly
        var polys = [poly1]
        if let p2 = poly2 { polys.append(p2) }
        let patchMesh = Euclid.Mesh(polys.compactMap { $0 })
        return patchMesh.polygons.isEmpty ? nil : patchMesh
    }

    /// Patches an open boundary loop onto an existing body mesh and seals it watertight.
    static func seal(mesh: Euclid.Mesh, loop: [SIMD3<Double>]) -> Euclid.Mesh {
        guard let p = patch(loop: loop) else { return mesh }
        return mesh.union(p).makeWatertight()
    }
}
