//
//  BodyMirrorTests.swift
//  openshape3dTests
//
//  Tests for 3D body mirroring across construction and planar faces,
//  including Keep Originals toggle and (Mirror) naming parity with Shapr3D.
//

import XCTest
import SwiftData
import simd
import Euclid
@testable import openshape3d

@MainActor
final class BodyMirrorTests: XCTestCase {

    private func makeViewModel() throws -> EditorViewModel {
        let schema = Schema([
            Project.self,
            PersistedBody.self,
            PersistedSketch.self,
            PersistedPlane.self,
            PersistedImage.self,
            PersistedSymbol.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let project = Project(name: "Mirror Test")
        context.insert(project)
        return EditorViewModel(project: project, modelContext: context)
    }

    private func addBox(
        to viewModel: EditorViewModel, name: String, at translation: SIMD3<Double>
    ) -> Body {
        var transform = Transform3D.identity
        transform.translation = translation
        var document = viewModel.session.document
        let body = Body(
            name: name,
            transform: transform,
            euclidMesh: .primitive(.box(width: 10, depth: 10, height: 10)),
            revision: document.nextRevision()
        )
        viewModel.session.perform(AddBodyCommand(body: body))
        return body
    }

    func testMirrorBodyPreservesOriginalWhenKeepOriginalIsTrue() throws {
        let vm = try makeViewModel()
        let body = addBox(to: vm, name: "Bracket", at: SIMD3<Double>(20, 0, 0))

        vm.selection = [body.id]
        vm.mirrorKeepOriginal = true
        vm.mirrorSelection(across: .worldYZ) // normal is (1, 0, 0), reflects x: 20 -> -20

        XCTAssertEqual(vm.session.document.bodies.count, 2)
        let mirrored = vm.session.document.bodies.first { $0.id != body.id }
        XCTAssertNotNil(mirrored)
        XCTAssertTrue(mirrored?.name.contains("Bracket (Mirror)") ?? false)
        XCTAssertEqual(mirrored?.transform.translation.x ?? 0, -20, accuracy: 1e-4)
    }

    func testMirrorBodyReplacesOriginalWhenKeepOriginalIsFalse() throws {
        let vm = try makeViewModel()
        let body = addBox(to: vm, name: "Pedal", at: SIMD3<Double>(0, 30, 0))

        vm.selection = [body.id]
        vm.mirrorKeepOriginal = false
        vm.mirrorSelection(across: .ground) // ground is ZX plane, normal is (0, 1, 0), reflects y: 30 -> -30

        XCTAssertEqual(vm.session.document.bodies.count, 1)
        let replaced = vm.session.document.bodies.first
        XCTAssertNotNil(replaced)
        XCTAssertTrue(replaced?.name.contains("Pedal (Mirror)") ?? false)
        XCTAssertEqual(replaced?.transform.translation.y ?? 0, -30, accuracy: 1e-4)
    }

    func testMirrorAcrossCustomFacePlane() throws {
        let vm = try makeViewModel()
        let body = addBox(to: vm, name: "Plate", at: .zero)

        vm.selection = [body.id]
        // Custom plane at x = 10, normal (1, 0, 0)
        let customPlane = SketchPlane(origin: SIMD3<Double>(10, 0, 0), xAxis: SIMD3<Double>(0, 0, 1), yAxis: SIMD3<Double>(0, 1, 0))
        vm.mirrorKeepOriginal = true
        vm.mirrorSelection(across: customPlane)

        XCTAssertEqual(vm.session.document.bodies.count, 2)
        let mirrored = vm.session.document.bodies.first { $0.id != body.id }
        XCTAssertNotNil(mirrored)
        // Original pivot at 0, plane at 10 -> 0 reflected across 10 is 20
        XCTAssertEqual(mirrored?.transform.translation.x ?? 0, 20, accuracy: 1e-4)
    }
}
