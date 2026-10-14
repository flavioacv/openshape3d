//
//  SlotConstruction.swift
//  openshape3d
//
//  Spec §1.3 / Shapr3D Overlay.SketchingSubMenu.SlotType:
//  Pure construction geometry for oblong / slot profiles (Center-to-Center Slot).
//  Produces closed boundary loops consisting of two semicircular arcs and two parallel lines.
//

import Foundation
import simd

nonisolated enum SlotConstruction {

    /// Generates the entities for a center-to-center slot:
    /// two tangent semicircular arcs centered at `center1` and `center2` with radius `radius`,
    /// joined by two parallel line segments.
    static func makeCenterSlot(
        center1: SIMD2<Double>,
        center2: SIMD2<Double>,
        radius: Double
    ) -> [SketchEntity] {
        guard radius > 1e-6 else { return [] }
        let delta = center2 - center1
        let length = simd_length(delta)
        guard length > 1e-6 else {
            // Degenerate slot with coincident centers is just a circle
            return [.circle(id: UUID(), center: center1, radius: radius)]
        }

        let dir = delta / length
        let perp = SIMD2<Double>(-dir.y, dir.x)
        let theta = atan2(dir.y, dir.x)

        let arc1Start = theta + .pi / 2
        let arc1End = theta + 3 * .pi / 2
        let arc2Start = theta - .pi / 2
        let arc2End = theta + .pi / 2

        let p1Top = center1 + perp * radius
        let p2Top = center2 + perp * radius
        let p1Bot = center1 - perp * radius
        let p2Bot = center2 - perp * radius

        let arc1 = SketchEntity.arc(
            id: UUID(), center: center1, radius: radius,
            startAngle: arc1Start, endAngle: arc1End
        )
        let arc2 = SketchEntity.arc(
            id: UUID(), center: center2, radius: radius,
            startAngle: arc2Start, endAngle: arc2End
        )
        let lineTop = SketchEntity.line(id: UUID(), a: p1Top, b: p2Top)
        let lineBot = SketchEntity.line(id: UUID(), a: p2Bot, b: p1Bot)

        return [arc1, lineTop, arc2, lineBot]
    }
}
