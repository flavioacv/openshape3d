//
//  STLExporter.swift
//  openshape3d
//
//  Binary STL export directly from high-precision B-rep tessellation
//  (`PrintExportKit`) when available, with Euclid fallback. Convention:
//  1 model unit = 1 mm (STL is unitless; slicers assume mm).
//

import Foundation
import simd

nonisolated enum STLExporter {
    static func binarySTL(bodies: [Body], resolution: PrintMeshResolution = .standard) -> Data {
        var meshes: [PrintExportKit.WorldMesh] = []
        meshes.reserveCapacity(bodies.count)
        var totalTriangles: UInt32 = 0
        for body in bodies {
            let mesh = PrintExportKit.worldMesh(for: body, resolution: resolution)
            meshes.append(mesh)
            totalTriangles += UInt32(mesh.indices.count / 3)
        }

        var data = Data(capacity: 84 + Int(totalTriangles) * 50)
        let header = "OpenShape3D BRep Binary STL (mm)".utf8
        data.append(contentsOf: header.prefix(80))
        if data.count < 80 {
            data.append(Data(repeating: 0, count: 80 - data.count))
        }
        var countLE = totalTriangles.littleEndian
        withUnsafeBytes(of: &countLE) { data.append(contentsOf: $0) }

        for mesh in meshes {
            let positions = mesh.positions
            let indices = mesh.indices
            var i = 0
            while i + 2 < indices.count {
                let p0 = positions[Int(indices[i])]
                let p1 = positions[Int(indices[i + 1])]
                let p2 = positions[Int(indices[i + 2])]
                let e1 = p1 - p0
                let e2 = p2 - p0
                let cross = simd_cross(e1, e2)
                let len = simd_length(cross)
                let n = len > 1e-12 ? (cross / len) : SIMD3<Float>(0, 0, 1)

                appendFloatLE(n.x, to: &data)
                appendFloatLE(n.y, to: &data)
                appendFloatLE(n.z, to: &data)
                appendFloatLE(p0.x, to: &data)
                appendFloatLE(p0.y, to: &data)
                appendFloatLE(p0.z, to: &data)
                appendFloatLE(p1.x, to: &data)
                appendFloatLE(p1.y, to: &data)
                appendFloatLE(p1.z, to: &data)
                appendFloatLE(p2.x, to: &data)
                appendFloatLE(p2.y, to: &data)
                appendFloatLE(p2.z, to: &data)
                data.append(contentsOf: [0, 0]) // attribute byte count
                i += 3
            }
        }
        return data
    }

    private static func appendFloatLE(_ value: Float, to data: inout Data) {
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }
}
