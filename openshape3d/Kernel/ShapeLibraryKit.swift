//
//  ShapeLibraryKit.swift
//  openshape3d
//
//  Parametric B-rep shape generators beyond the basic Box/Cylinder/Sphere
//  primitives: Cone/Frustum, Torus, Wedge, Hollow Tube, Polygonal Prism
//  (e.g. hex nut/bolt), Involute Spur Gear, and Helical Coil Spring.
//

import Foundation
import simd

nonisolated enum ShapeLibraryKit {

    static func makeBody(name: String, handle: BRepHandle) -> Body? {
        var body = Body(
            id: BodyID(),
            name: name,
            transform: .identity,
            primitive: nil,
            render: RenderMesh(positions: [], normals: [], indices: []),
            revision: 1
        )
        guard body.adoptBRep(handle, keepingFaceRegions: true) else { return nil }
        return body
    }

    static func cone(bottomRadius: Double, topRadius: Double, height: Double,
                     name: String = "Cone") -> Body? {
        guard let h = OCCTKernel.cone(bottomRadius: bottomRadius, topRadius: topRadius, height: height) else {
            return nil
        }
        return makeBody(name: name, handle: h)
    }

    static func torus(majorRadius: Double, minorRadius: Double,
                      name: String = "Torus") -> Body? {
        guard let h = OCCTKernel.torus(majorRadius: majorRadius, minorRadius: minorRadius) else {
            return nil
        }
        return makeBody(name: name, handle: h)
    }

    static func wedge(dx: Double, depth: Double, height: Double,
                      name: String = "Wedge") -> Body? {
        guard let h = OCCTKernel.wedge(dx: dx, depth: depth, height: height) else {
            return nil
        }
        return makeBody(name: name, handle: h)
    }

    static func tube(outerRadius: Double, innerRadius: Double, height: Double,
                     name: String = "Tube") -> Body? {
        guard let h = OCCTKernel.tube(outerRadius: outerRadius, innerRadius: innerRadius, height: height) else {
            return nil
        }
        return makeBody(name: name, handle: h)
    }

    static func polygonalPrism(sides: Int, radius: Double, height: Double,
                               name: String? = nil) -> Body? {
        guard let h = OCCTKernel.polygonalPrism(sides: sides, radius: radius, height: height) else {
            return nil
        }
        return makeBody(name: name ?? "\(sides)-Sided Prism", handle: h)
    }

    /// Parametric involute spur gear (1 unit = 1 mm) with optional center bore,
    /// ready for 3D printing.
    static func spurGear(
        module: Double = 2.0,
        teeth: Int = 16,
        thickness: Double = 8.0,
        pressureAngleDeg: Double = 20.0,
        boreRadius: Double = 3.0,
        name: String = "Spur Gear"
    ) -> Body? {
        guard module > 0.1, teeth >= 6, thickness > 0.2 else { return nil }
        let z = Double(teeth)
        let pitchR = 0.5 * module * z
        let addendum = module
        let dedendum = 1.25 * module
        let outerR = pitchR + addendum
        let rootR = max(0.5, pitchR - dedendum)
        let alpha = pressureAngleDeg * .pi / 180.0
        let baseR = pitchR * cos(alpha)

        let invAlpha = tan(alpha) - alpha
        let halfToothPitchAngle = (.pi / (2.0 * z)) + invAlpha

        func involuteAngle(at r: Double) -> Double {
            guard r > baseR else { return 0 }
            let phi = acos(baseR / r)
            return tan(phi) - phi
        }

        var loop: [SIMD2<Double>] = []
        let toothStep = (2.0 * .pi) / z
        let flankSamples = 4

        for i in 0..<teeth {
            let centerAngle = Double(i) * toothStep
            let rootStart = centerAngle - toothStep * 0.5
            let flankStartR = max(rootR, baseR)

            // Root arc start
            loop.append(SIMD2(rootR * cos(rootStart), rootR * sin(rootStart)))

            // Rising flank
            for s in 0...flankSamples {
                let t = Double(s) / Double(flankSamples)
                let r = flankStartR + (outerR - flankStartR) * t
                let a = centerAngle - halfToothPitchAngle + involuteAngle(at: r)
                loop.append(SIMD2(r * cos(a), r * sin(a)))
            }

            // Tip & falling flank
            for s in (0...flankSamples).reversed() {
                let t = Double(s) / Double(flankSamples)
                let r = flankStartR + (outerR - flankStartR) * t
                let a = centerAngle + halfToothPitchAngle - involuteAngle(at: r)
                loop.append(SIMD2(r * cos(a), r * sin(a)))
            }
        }

        var holes: [OCCTKernel.ExtrudeHole] = []
        if boreRadius > 0.2 && boreRadius < rootR - 0.3 {
            let n = 48
            var boreLoop: [SIMD2<Double>] = []
            boreLoop.reserveCapacity(n)
            for i in 0..<n {
                let a = (2.0 * .pi * Double(i)) / Double(n)
                boreLoop.append(SIMD2(boreRadius * cos(a), boreRadius * sin(a)))
            }
            holes.append(OCCTKernel.ExtrudeHole(
                loop: boreLoop,
                conic: OCCTKernel.ConicSpec(center: .zero, radius: boreRadius)
            ))
        }

        guard let handle = OCCTKernel.extrudeShape(
            outerLoop: loop,
            holes: holes,
            zMin: 0.0,
            zMax: thickness,
            origin: .zero,
            xAxis: SIMD3(1, 0, 0),
            yAxis: SIMD3(0, 0, -1),
            normal: SIMD3(0, 1, 0)
        ) else {
            return nil
        }
        return makeBody(name: name, handle: handle)
    }

    /// Exact helical coil spring swept along `OS3DHelixWire`.
    static func coilSpring(
        coilRadius: Double = 8.0,
        wireRadius: Double = 1.2,
        pitch: Double = 4.0,
        turns: Double = 5.0,
        name: String = "Coil Spring"
    ) -> Body? {
        guard coilRadius > wireRadius + 0.2, wireRadius > 0.05, pitch > wireRadius * 2.05, turns >= 0.5 else {
            return nil
        }

        let n = 24
        var circle2D: [Double] = []
        circle2D.reserveCapacity(n * 2)
        for i in 0..<n {
            let a = (2.0 * .pi * Double(i)) / Double(n)
            circle2D.append(coilRadius + wireRadius * cos(a))
            circle2D.append(wireRadius * sin(a))
        }
        let loopData = circle2D.withUnsafeBytes { Data($0) }

        let basis = OCCTPlaneBasis(
            originX: 0, originY: 0, originZ: 0,
            xAxisX: 1, xAxisY: 0, xAxisZ: 0,
            yAxisX: 0, yAxisY: 1, yAxisZ: 0,
            normalX: 0, normalY: 0, normalZ: 1
        )
        let helixValues: [Double] = [
            0, 0, 0,
            0, 1, 0,
            1, 0, 0,
            coilRadius, pitch, turns, 0
        ]
        let helixData = helixValues.withUnsafeBytes { Data($0) }
        let spinePts: [Double] = [coilRadius, 0, 0, coilRadius, pitch * turns, 0]
        let spineData = spinePts.withUnsafeBytes { Data($0) }

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
        return makeBody(name: name, handle: BRepHandle(shape))
    }
}
