//
//  PatchKitTests.swift
//  openshape3dTests
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class PatchKitTests: XCTestCase {

    func testPatchCreatesClosedFace() {
        let loop = [
            SIMD3<Double>(0, 0, 0),
            SIMD3<Double>(10, 0, 0),
            SIMD3<Double>(10, 10, 0),
            SIMD3<Double>(0, 10, 0)
        ]
        let patchMesh = PatchKit.patch(loop: loop)
        XCTAssertNotNil(patchMesh)
        XCTAssertFalse(patchMesh?.polygons.isEmpty ?? true)
    }

    func testDegenerateLoopProducesNil() {
        let loop = [
            SIMD3<Double>(0, 0, 0),
            SIMD3<Double>(1, 1, 1)
        ]
        XCTAssertNil(PatchKit.patch(loop: loop))
    }

    func testSealBoundaryOntoMesh() {
        let baseCube = Euclid.Mesh.primitive(.box(width: 10, depth: 10, height: 10))
        let capLoop = [
            SIMD3<Double>(-5, 10, -5),
            SIMD3<Double>(5, 10, -5),
            SIMD3<Double>(5, 10, 5),
            SIMD3<Double>(-5, 10, 5)
        ]
        let sealed = PatchKit.seal(mesh: baseCube, loop: capLoop)
        XCTAssertFalse(sealed.polygons.isEmpty)
        XCTAssertTrue(sealed.isWatertight)
    }
}
