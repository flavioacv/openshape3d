//
//  CornerBlendAndDefeatureParityTests.swift
//  openshape3dTests
//
//  Shapr3D modeling, extrusion, chamfer/fillet, and localized corner healing
//  parity tests (docs/SHAPR3D_MODELING_EXTRUDE_BLEND_SDD.md).
//

import XCTest
import SwiftData
import simd
@testable import openshape3d

@MainActor
final class CornerBlendAndDefeatureParityTests: XCTestCase {
    nonisolated(unsafe) static var retained: [EditorViewModel] = []

    private func makeViewModel() throws -> EditorViewModel {
        let schema = Schema([
            Project.self, PersistedBody.self, PersistedSketch.self,
            PersistedPlane.self, PersistedImage.self, PersistedSymbol.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let project = Project(name: "CornerBlendParityTest")
        context.insert(project)
        let vm = EditorViewModel(project: project, modelContext: context)
        Self.retained.append(vm)
        return vm
    }

    private func renderMesh(_ handle: BRepHandle) -> RenderMesh {
        let m = OCCTKernel.renderMesh(from: handle)
        return RenderMesh(positions: m.positions, normals: m.normals, indices: m.indices)
    }

    private func triangleCentroid(_ mesh: RenderMesh, _ t: Int) -> SIMD3<Double> {
        let a = mesh.positions[Int(mesh.indices[t * 3])]
        let b = mesh.positions[Int(mesh.indices[t * 3 + 1])]
        let c = mesh.positions[Int(mesh.indices[t * 3 + 2])]
        return SIMD3<Double>(
            Double(a.x + b.x + c.x) / 3.0,
            Double(a.y + b.y + c.y) / 3.0,
            Double(a.z + b.z + c.z) / 3.0
        )
    }

    // MARK: - SPEC-01 & SPEC-05: Localized single-corner fillet removal in all 4 quadrants

    /// When a 20×20×20 box has all 4 vertical edges filleted to R = 3 mm,
    /// deleting ANY single rounded corner via `DeleteFaceKit` + `OCCTKernel.removingFaces`
    /// must:
    /// 1. Isolate only that single 90° fillet face (never leaking across G¹
    ///    tangent boundaries into adjacent planar walls or neighbouring fillets).
    /// 2. Sample a point ON the trimmed 90° quarter-cylinder in all 4 quadrants
    ///    ((+X,+Z), (-X,+Z), (-X,-Z), (+X,-Z)).
    /// 3. Heal ONLY that corner back to a sharp 90° edge, leaving the other 3
    ///    rounded corners intact (cylindrical face count drops from 4 to 3, and
    ///    planar face count remains 6 without merging adjacent faces).
    func testDeletingSingleRoundedCornerRestoresOnlyThatCornerInAllFourQuadrants() throws {
        let box = try XCTUnwrap(
            OCCTKernel.primitiveShape(.box(width: 20, depth: 20, height: 20),
                                      placement: .identity)
        )
        // Box spans X in [-10, 10], Y in [0, 20], Z in [-10, 10].
        let cornerEdgeMidpoints: [SIMD3<Double>] = [
            SIMD3<Double>( 10, 10,  10),
            SIMD3<Double>(-10, 10,  10),
            SIMD3<Double>(-10, 10, -10),
            SIMD3<Double>( 10, 10, -10),
        ]
        let tol = OCCTKernel.matchTolerance(for: box)
        let filleted4 = try XCTUnwrap(
            OCCTKernel.fillet(box, at: cornerEdgeMidpoints, radius: 3.0, tolerance: tol),
            "4 vertical edges filleted to R=3"
        )
        let initialCounts = OCCTKernel.faceTypeCounts(filleted4)
        XCTAssertEqual(initialCounts.planar, 6, "6 planar walls/caps")
        XCTAssertEqual(initialCounts.cylindrical, 4, "4 quarter-cylinder fillet faces")

        let mesh = renderMesh(filleted4)

        for (quadrantIndex, corner) in cornerEdgeMidpoints.enumerated() {
            // Find a triangle belonging to this corner's fillet near mid-height Y=10.
            let sx = corner.x > 0 ? 1.0 : -1.0
            let sz = corner.z > 0 ? 1.0 : -1.0
            // On a R=3 fillet at (±10, Y, ±10), the arc midpoint sits at
            // (±(10 - 3 + 3/√2), 10, ±(10 - 3 + 3/√2)) ≈ (±9.121, 10, ±9.121).
            let expectedArcMid = SIMD3<Double>(sx * (7.0 + 3.0 * sqrt(0.5)), 10.0, sz * (7.0 + 3.0 * sqrt(0.5)))

            var bestTri: Int?
            var bestDist = Double.infinity
            for t in 0..<mesh.triangleCount {
                let c = triangleCentroid(mesh, t)
                let d = hypot(c.x - expectedArcMid.x, c.z - expectedArcMid.z)
                if d < bestDist {
                    bestDist = d
                    bestTri = t
                }
            }
            let seed = try XCTUnwrap(bestTri, "seed triangle in quadrant \(quadrantIndex)")
            XCTAssertLessThan(bestDist, 1.0, "seed triangle must lie on the fillet in quadrant \(quadrantIndex)")

            let target = try XCTUnwrap(
                DeleteFaceKit.target(in: mesh, seedTriangle: seed),
                "DeleteFaceKit must recognize the 90° fillet in quadrant \(quadrantIndex)"
            )
            // Must isolate ONLY this single fillet face (not all 4 fillets + walls).
            XCTAssertLessThan(
                target.triangles.count, mesh.triangleCount / 3,
                "smooth/cylindrical flood must not leak into tangent planar walls in quadrant \(quadrantIndex)"
            )

            // Sample point must lie in the same (X, Z) quadrant as the picked corner.
            XCTAssertEqual(target.samplePoint.x > 0, corner.x > 0,
                           "samplePoint X sign must match quadrant \(quadrantIndex)")
            XCTAssertEqual(target.samplePoint.z > 0, corner.z > 0,
                           "samplePoint Z sign must match quadrant \(quadrantIndex)")

            // Heal the single corner via OCCT BRepAlgoAPI_Defeaturing.
            let healed = try XCTUnwrap(
                OCCTKernel.removingFaces(
                    filleted4,
                    at: [target.samplePoint],
                    tolerance: OCCTKernel.matchTolerance(for: filleted4)
                ),
                "OCCT defeaturing must heal the single fillet in quadrant \(quadrantIndex)"
            )

            let afterCounts = OCCTKernel.faceTypeCounts(healed)
            XCTAssertEqual(
                afterCounts.cylindrical, 3,
                "Quadrant \(quadrantIndex): only the picked fillet is removed; the other 3 rounded corners remain untouched"
            )
            XCTAssertEqual(
                afterCounts.planar, 6,
                "Quadrant \(quadrantIndex): the 6 planar faces remain distinct without improper merging"
            )
        }
    }

    // MARK: - SPEC-05: 3-edge corner blend patch (spherical vertex patch) & chamfer defeaturing

    /// When 3 edges meeting at a vertex are filleted, OCCT generates 3
    /// cylindrical edge fillets plus 1 spherical/toroidal corner patch at the
    /// vertex. Selecting and deleting one of the fillets or a chamfer face heals
    /// locally.
    func testDeletingChamferFaceRestoresSharpCornerLocally() throws {
        let box = try XCTUnwrap(
            OCCTKernel.primitiveShape(.box(width: 20, depth: 20, height: 20),
                                      placement: .identity)
        )
        let tol = OCCTKernel.matchTolerance(for: box)
        let chamfered = try XCTUnwrap(
            OCCTKernel.chamfer(
                box,
                at: [SIMD3<Double>(10, 10, 10), SIMD3<Double>(-10, 10, 10)],
                distance: 3.0,
                tolerance: tol
            ),
            "2 vertical edges chamfered"
        )
        let beforeCounts = OCCTKernel.faceTypeCounts(chamfered)
        XCTAssertEqual(beforeCounts.planar, 8, "6 box faces + 2 chamfer bevels")

        let mesh = renderMesh(chamfered)
        // Pick the (+X, +Z) chamfer face around (8.5, 10, 8.5).
        var seedTri: Int?
        var bestDist = Double.infinity
        for t in 0..<mesh.triangleCount {
            let c = triangleCentroid(mesh, t)
            let d = simd_distance(c, SIMD3<Double>(8.5, 10.0, 8.5))
            if d < bestDist {
                bestDist = d
                seedTri = t
            }
        }
        let seed = try XCTUnwrap(seedTri)
        let target = try XCTUnwrap(DeleteFaceKit.target(in: mesh, seedTriangle: seed))

        let healed = try XCTUnwrap(
            OCCTKernel.removingFaces(
                chamfered,
                at: [target.samplePoint],
                tolerance: OCCTKernel.matchTolerance(for: chamfered)
            ),
            "Deleting one chamfer bevel must restore that sharp corner"
        )
        let afterCounts = OCCTKernel.faceTypeCounts(healed)
        XCTAssertEqual(afterCounts.planar, 7, "1 chamfer bevel removed, the other chamfer + 6 box faces remain")
    }

    // MARK: - SPEC-04: Asymmetric 2-Distance Chamfer on OCCT B-Rep

    func testAsymmetricTwoDistanceChamferProducesExactAnalyticBevel() throws {
        let box = try XCTUnwrap(
            OCCTKernel.primitiveShape(.box(width: 20, depth: 20, height: 20),
                                      placement: .identity)
        )
        let tol = OCCTKernel.matchTolerance(for: box)
        let edgePt = [SIMD3<Double>(10, 20, 0)]

        let sym = try XCTUnwrap(
            OCCTKernel.chamfer(box, at: edgePt, distance: 2.0, distance2: 2.0, tolerance: tol),
            "symmetric 2×2 mm chamfer"
        )
        let asym = try XCTUnwrap(
            OCCTKernel.chamfer(box, at: edgePt, distance: 2.0, distance2: 5.0, tolerance: tol),
            "asymmetric 2×5 mm chamfer"
        )

        // Volume removed by a 2×2 chamfer along a 20 mm edge is 0.5 * 2 * 2 * 20 = 40 mm³ (8000 - 40 = 7960).
        // Volume removed by a 2×5 chamfer along a 20 mm edge is 0.5 * 2 * 5 * 20 = 100 mm³ (8000 - 100 = 7900).
        let symVol = OCCTKernel.volume(sym)
        let asymVol = OCCTKernel.volume(asym)
        XCTAssertEqual(symVol, 8000.0 - 40.0, accuracy: 0.5)
        XCTAssertEqual(asymVol, 8000.0 - 100.0, accuracy: 0.5)
    }

    // MARK: - SPEC-05 & SPEC-06: Direct Face Selection + 1-Tap Delete Face in EditorViewModel

    func testDeleteSelectedFaceHealsFilletCornerWithoutDeletingBody() throws {
        let vm = try makeViewModel()

        // Create a 20×20×20 B-Rep box with one filleted vertical corner (+X, +Z).
        let box = try XCTUnwrap(
            OCCTKernel.primitiveShape(.box(width: 20, depth: 20, height: 20),
                                      placement: .identity)
        )
        let tol = OCCTKernel.matchTolerance(for: box)
        let filleted = try XCTUnwrap(
            OCCTKernel.fillet(box, at: [SIMD3<Double>(10, 10, 10)], radius: 3.0, tolerance: tol)
        )
        let bodyID = BodyID()
        var body = Body(
            id: bodyID, name: "FilletedBox", transform: .identity,
            primitive: nil, euclidMesh: .empty, revision: 1
        )
        XCTAssertTrue(body.adoptBRep(filleted))
        vm.session.perform(AddBodyCommand(body: body))

        // Locate a triangle on the fillet face.
        let mesh = body.render
        let targetPt = SIMD3<Double>(7.0 + 3.0 * sqrt(0.5), 10.0, 7.0 + 3.0 * sqrt(0.5))
        var seedTri: Int?
        var bestDist = Double.infinity
        for t in 0..<mesh.triangleCount {
            let c = triangleCentroid(mesh, t)
            let d = simd_distance(c, targetPt)
            if d < bestDist {
                bestDist = d
                seedTri = t
            }
        }
        let seed = try XCTUnwrap(seedTri)
        let smooth = try XCTUnwrap(FaceTopology.smoothRegion(in: mesh, seedTriangle: seed))
        XCTAssertTrue(smooth.isCurved)

        // Simulate selecting the curved fillet face in `.faceSelected` mode.
        vm.selection = [bodyID]
        vm.mode = .faceSelected(bodyID)
        vm.toolContext = EditorViewModel.ToolContext(
            profile: Profile(loop: [], kind: .polygonal, sourceEntityIDs: []),
            holes: [],
            plane: .ground,
            sketchID: nil,
            sourceBody: bodyID,
            faceTriangles: smooth.triangles,
            curvedRegion: true,
            kind: .extrude(distance: 0)
        )

        XCTAssertTrue(vm.canDeleteSelectedFace, "Selected fillet face should be deletable/healable")

        // Pressing Delete (deleteSelection) must heal the fillet face locally, NOT delete the body!
        vm.deleteSelection()

        let healedBody = try XCTUnwrap(
            vm.session.document.bodies.first(where: { $0.id == bodyID }),
            "Body must survive face deletion"
        )
        let healedBRep = try XCTUnwrap(healedBody.brep)
        let counts = OCCTKernel.faceTypeCounts(healedBRep)
        XCTAssertEqual(counts.cylindrical, 0, "Fillet corner is healed away")
        XCTAssertEqual(counts.planar, 6, "Sharp 6-face box is restored")
    }
}
