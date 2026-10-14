//
//  HapticFeedback.swift
//  openshape3d
//
//  Shapr3D-style micro-haptic clicks for snapping to whole dimensions and geometric guides.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

@MainActor
enum HapticFeedback {
    #if canImport(UIKit)
    private static let impactGen = UIImpactFeedbackGenerator(style: .light)
    private static let selectGen = UISelectionFeedbackGenerator()
    #endif

    /// Quick light tick when snapping onto a round number or geometry feature
    static func snapOccurred() {
        #if canImport(UIKit)
        selectGen.selectionChanged()
        #elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
        NSHapticFeedbackManager.defaultPerformer.perform(
            .alignment, performanceTime: .default)
        #endif
    }

    /// Satisfying click when an operation completes or locks
    static func commitOccurred() {
        #if canImport(UIKit)
        impactGen.impactOccurred()
        #elseif canImport(AppKit) && !targetEnvironment(macCatalyst)
        NSHapticFeedbackManager.defaultPerformer.perform(
            .levelChange, performanceTime: .default)
        #endif
    }
}
