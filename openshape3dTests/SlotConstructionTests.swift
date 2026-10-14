//
//  SlotConstructionTests.swift
//  openshape3dTests
//

import XCTest
import simd
@testable import openshape3d

final class SlotConstructionTests: XCTestCase {

    func testSlotProducesFourConnectedEntities() {
        let c1 = SIMD2<Double>(0, 0)
        let c2 = SIMD2<Double>(10, 0)
        let r = 2.5
        let entities = SlotConstruction.makeCenterSlot(center1: c1, center2: c2, radius: r)

        XCTAssertEqual(entities.count, 4, "Slot must produce 2 arcs and 2 lines")
    }

    func testSlotFormsClosedProfileRecognizedByProfileDetector() {
        let c1 = SIMD2<Double>(0, 0)
        let c2 = SIMD2<Double>(20, 0)
        let r = 5.0
        let entities = SlotConstruction.makeCenterSlot(center1: c1, center2: c2, radius: r)

        var sketch = Sketch(name: "SlotSketch", plane: .ground)
        sketch.entities = entities

        let profiles = ProfileDetector.detectProfiles(in: sketch)
        XCTAssertEqual(profiles.count, 1, "Slot must form exactly one closed profile fill")

        if let profile = profiles.first {
            let expectedArea = (2 * r * 20.0) + (.pi * r * r) // 200 + 25*pi ≈ 278.5398
            XCTAssertEqual(profile.area, expectedArea, accuracy: 2.0, "Profile area matches analytic slot formula")
        }
    }

    func testDegenerateSlotProducesCircle() {
        let c = SIMD2<Double>(5, 5)
        let entities = SlotConstruction.makeCenterSlot(center1: c, center2: c, radius: 3.0)
        XCTAssertEqual(entities.count, 1)
        if case let .circle(_, center, radius) = entities[0] {
            XCTAssertEqual(center, c)
            XCTAssertEqual(radius, 3.0)
        } else {
            XCTFail("Degenerate slot with coincident centers must produce a circle")
        }
    }
}
