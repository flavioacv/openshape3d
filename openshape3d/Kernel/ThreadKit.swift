//
//  ThreadKit.swift
//  openshape3d
//
//  Parametric 3D-printable ISO Metric & UNC threads over exact OCCT helices
//  (`OS3DHelixWire` / `OCCTKernel.sweepSolid`), with configurable radial
//  printing clearance and external (union) / internal (cut) boolean ops.
//

import Foundation
import simd

nonisolated enum ThreadStandard: Sendable, Equatable, CaseIterable {
    // ISO Metric coarse series
    case m3, m4, m5, m6, m8, m10, m12, m16, m20, m24
    // Unified National Coarse (mm equivalents)
    case unc6_32, unc8_32, unc10_24, unc1_4_20, unc5_16_18, unc3_8_16, unc1_2_13

    var displayName: String {
        switch self {
        case .m3: return "M3 x 0.5"
        case .m4: return "M4 x 0.7"
        case .m5: return "M5 x 0.8"
        case .m6: return "M6 x 1.0"
        case .m8: return "M8 x 1.25"
        case .m10: return "M10 x 1.5"
        case .m12: return "M12 x 1.75"
        case .m16: return "M16 x 2.0"
        case .m20: return "M20 x 2.5"
        case .m24: return "M24 x 3.0"
        case .unc6_32: return "#6-32 UNC"
        case .unc8_32: return "#8-32 UNC"
        case .unc10_24: return "#10-24 UNC"
        case .unc1_4_20: return "1/4-20 UNC"
        case .unc5_16_18: return "5/16-18 UNC"
        case .unc3_8_16: return "3/8-16 UNC"
        case .unc1_2_13: return "1/2-13 UNC"
        }
    }

    /// Major diameter in millimeters.
    var majorDiameterMM: Double {
        switch self {
        case .m3: return 3.0
        case .m4: return 4.0
        case .m5: return 5.0
        case .m6: return 6.0
        case .m8: return 8.0
        case .m10: return 10.0
        case .m12: return 12.0
        case .m16: return 16.0
        case .m20: return 20.0
        case .m24: return 24.0
        case .unc6_32: return 3.505
        case .unc8_32: return 4.166
        case .unc10_24: return 4.826
        case .unc1_4_20: return 6.350
        case .unc5_16_18: return 7.938
        case .unc3_8_16: return 9.525
        case .unc1_2_13: return 12.700
        }
    }

    /// Pitch in millimeters.
    var pitchMM: Double {
        switch self {
        case .m3: return 0.5
        case .m4: return 0.7
        case .m5: return 0.8
        case .m6: return 1.0
        case .m8: return 1.25
        case .m10: return 1.5
        case .m12: return 1.75
        case .m16: return 2.0
        case .m20: return 2.5
        case .m24: return 3.0
        case .unc6_32: return 25.4 / 32.0
        case .unc8_32: return 25.4 / 32.0
        case .unc10_24: return 25.4 / 24.0
        case .unc1_4_20: return 25.4 / 20.0
        case .unc5_16_18: return 25.4 / 18.0
        case .unc3_8_16: return 25.4 / 16.0
        case .unc1_2_13: return 25.4 / 13.0
        }
    }

    /// Closest standard thread for a picked cylinder diameter (mm).
    static func nearest(forDiameterMM d: Double) -> ThreadStandard {
        allCases.min(by: { abs($0.majorDiameterMM - d) < abs($1.majorDiameterMM - d) }) ?? .m6
    }
}

nonisolated struct ThreadSpec: Sendable, Equatable {
    var majorDiameter: Double
    var pitch: Double
    var length: Double
    var isInternal: Bool
    var rightHanded: Bool
    /// Radial 3D-printing clearance (mm): shrinks external crests / expands internal grooves.
    var clearanceMM: Double

    init(standard: ThreadStandard, length: Double, isInternal: Bool = false,
         rightHanded: Bool = true, clearanceMM: Double = 0.15) {
        self.majorDiameter = standard.majorDiameterMM
        self.pitch = standard.pitchMM
        self.length = length
        self.isInternal = isInternal
        self.rightHanded = rightHanded
        self.clearanceMM = clearanceMM
    }

    init(majorDiameter: Double, pitch: Double, length: Double,
         isInternal: Bool = false, rightHanded: Bool = true, clearanceMM: Double = 0.15) {
        self.majorDiameter = majorDiameter
        self.pitch = pitch
        self.length = length
        self.isInternal = isInternal
        self.rightHanded = rightHanded
        self.clearanceMM = clearanceMM
    }
}

nonisolated enum ThreadKit {

    /// Build the exact helical thread ridge/groove B-rep tool along `axis`
    /// starting at `origin`.
    static func buildThreadTool(
        origin: SIMD3<Double>,
        axis: SIMD3<Double>,
        spec: ThreadSpec
    ) -> BRepHandle? {
        guard spec.majorDiameter > 0.5, spec.pitch > 0.1, spec.length > spec.pitch * 0.5 else {
            return nil
        }

        let dir = simd_normalize(axis)
        let refSeed = abs(dir.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
        let radialDir = simd_normalize(simd_cross(refSeed, dir))
        let tangentDir = simd_normalize(simd_cross(dir, radialDir))

        // ISO 60-degree trapezoidal profile:
        // H = sqrt(3)/2 * P, working thread depth = 5/8 * H (~0.54127 * P).
        let p = spec.pitch
        let h = (sqrt(3.0) / 2.0) * p
        let depth = (5.0 / 8.0) * h
        let baseR = spec.majorDiameter * 0.5

        // Slight radial overlap into the host cylinder guarantees clean boolean union/cut.
        let overlap = max(0.05, p * 0.12)
        let innerR: Double
        let outerR: Double
        if spec.isInternal {
            innerR = baseR - overlap
            outerR = baseR + depth + spec.clearanceMM
        } else {
            innerR = max(0.1, baseR - depth - overlap)
            outerR = max(innerR + 0.05, baseR - spec.clearanceMM)
        }

        let halfBase = p * 0.44
        let halfCrest = p * 0.08
        // Profile in plane (X = radial outward, Y = axial along thread):
        let loop2D: [SIMD2<Double>] = [
            SIMD2(innerR, -halfBase),
            SIMD2(outerR, -halfCrest),
            SIMD2(outerR, halfCrest),
            SIMD2(innerR, halfBase)
        ]

        // Plane at `origin`, X = radialDir, Y = dir, normal = tangentDir (right-handed).
        let basis = OCCTPlaneBasis(
            originX: origin.x, originY: origin.y, originZ: origin.z,
            xAxisX: radialDir.x, xAxisY: radialDir.y, xAxisZ: radialDir.z,
            yAxisX: dir.x, yAxisY: dir.y, yAxisZ: dir.z,
            normalX: tangentDir.x, normalY: tangentDir.y, normalZ: tangentDir.z
        )

        let turns = spec.length / p
        let signedTurns = spec.rightHanded ? turns : -turns
        let helixValues: [Double] = [
            origin.x, origin.y, origin.z,
            dir.x, dir.y, dir.z,
            radialDir.x, radialDir.y, radialDir.z,
            innerR, p, signedTurns, 0.0
        ]
        let helixData = helixValues.withUnsafeBytes { Data($0) }
        let spinePts: [Double] = [
            origin.x + radialDir.x * innerR, origin.y + radialDir.y * innerR, origin.z + radialDir.z * innerR,
            origin.x + radialDir.x * innerR + dir.x * spec.length,
            origin.y + radialDir.y * innerR + dir.y * spec.length,
            origin.z + radialDir.z * innerR + dir.z * spec.length
        ]
        let spineData = spinePts.withUnsafeBytes { Data($0) }
        let loopData = loop2D.flatMap { [$0.x, $0.y] }.withUnsafeBytes { Data($0) }

        guard let shape = OCCTBridge.sweptShape(
            withOuterLoop: loopData,
            outerConic: nil,
            holes: [],
            holeConics: nil,
            outerSegments: nil,
            holeSegments: nil,
            basis: basis,
            spine: spineData,
            helix: helixData,
            history: nil
        ) else {
            return nil
        }
        return BRepHandle(shape)
    }

    /// Apply external (union) or internal (cut) 3D-printable threads onto `target`.
    static func applyThread(
        to target: BRepHandle,
        origin: SIMD3<Double>,
        axis: SIMD3<Double>,
        spec: ThreadSpec
    ) -> Result<BRepHandle, OCCTOpError> {
        guard let tool = buildThreadTool(origin: origin, axis: axis, spec: spec) else {
            return .failure(.kernelRefused("Could not generate helical thread geometry."))
        }
        let op = spec.isInternal ? 1 : 0 // 0 = union, 1 = subtract
        return OCCTKernel.booleanResult(target, tool, op: op).map(\.handle)
    }
}
