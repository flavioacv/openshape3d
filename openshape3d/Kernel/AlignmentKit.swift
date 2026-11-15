//
//  AlignmentKit.swift
//  openshape3d
//
//  Exact geometric alignment helpers (Shapr3D `AlignmentHelpers` parity):
//  face-to-face planar mating, coaxial cylinder/cone alignment, and point/origin
//  snapping. Returns the `Transform3D` delta to compose onto a `Body`.
//

import Foundation
import simd

nonisolated enum AlignmentKit {

    /// Quaternion rotating unit vector `from` onto unit vector `to`, handling
    /// the anti-parallel 180-degree singularity cleanly.
    static func rotationBetween(_ from: SIMD3<Double>, _ to: SIMD3<Double>) -> simd_quatd {
        let a = simd_normalize(from)
        let b = simd_normalize(to)
        let dot = max(-1.0, min(1.0, simd_dot(a, b)))
        if dot > 0.999_999 {
            return simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        }
        if dot < -0.999_999 {
            let ref = abs(a.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
            let axis = simd_normalize(simd_cross(a, ref))
            return simd_quatd(angle: .pi, axis: axis)
        }
        return simd_quatd(from: a, to: b)
    }

    /// World-space transform delta that mates `sourceOrigin`/`sourceNormal`
    /// flush against `targetOrigin`/`targetNormal` (norms become opposite when
    /// `mateOpposite == true`, or co-directional when `false`).
    static func alignPlanar(
        sourceOrigin: SIMD3<Double>,
        sourceNormal: SIMD3<Double>,
        targetOrigin: SIMD3<Double>,
        targetNormal: SIMD3<Double>,
        mateOpposite: Bool = true
    ) -> Transform3D {
        let desiredNormal = mateOpposite ? -simd_normalize(targetNormal) : simd_normalize(targetNormal)
        let rot = rotationBetween(sourceNormal, desiredNormal)
        let rotatedOrigin = rot.act(sourceOrigin)
        var delta = Transform3D()
        delta.rotation = rot
        delta.translation = targetOrigin - rotatedOrigin
        return delta
    }

    /// World-space transform delta that aligns a cylindrical/conical axis
    /// (`sourcePoint`, `sourceAxis`) coaxially onto (`targetPoint`, `targetAxis`),
    /// projecting `sourcePoint` onto the target axis line.
    static func alignAxis(
        sourcePoint: SIMD3<Double>,
        sourceAxis: SIMD3<Double>,
        targetPoint: SIMD3<Double>,
        targetAxis: SIMD3<Double>,
        flipDirection: Bool = false
    ) -> Transform3D {
        let dirTarget = flipDirection ? -simd_normalize(targetAxis) : simd_normalize(targetAxis)
        let rot = rotationBetween(sourceAxis, dirTarget)
        let rotatedPoint = rot.act(sourcePoint)
        let offset = targetPoint - rotatedPoint
        // Keep axial slide minimal by shifting perpendicular to target axis.
        let perpShift = offset - dirTarget * simd_dot(offset, dirTarget)
        var delta = Transform3D()
        delta.rotation = rot
        delta.translation = perpShift
        return delta
    }

    /// Pure translation delta aligning two world-space reference points
    /// (e.g., sphere centers, circular edge centers, or vertices).
    static func alignPoints(from source: SIMD3<Double>, to target: SIMD3<Double>) -> Transform3D {
        var delta = Transform3D()
        delta.translation = target - source
        return delta
    }
}
