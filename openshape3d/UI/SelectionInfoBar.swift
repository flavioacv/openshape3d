//
//  SelectionInfoBar.swift
//  openshape3d
//
//  Bottom selection info strip (spec §16.3): volume + bounds for a body,
//  area + perimeter for a face, length/radius for sketch entities. Read-only —
//  values come straight from EditorViewModel.selectionMeasurements.
//

import SwiftUI

struct SelectionInfoBar: View {
    @Bindable var viewModel: EditorViewModel

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isCompact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        let rows = viewModel.selectionMeasurements
        if !rows.isEmpty {
            strip(rows)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                // A capsule around a strip that has had to wrap looks broken;
                // at compact width the strip scrolls instead, so it stays one
                // line and the capsule still fits it.
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                .accessibilityIdentifier("SelectionInfoBar")
        }
    }

    @ViewBuilder
    private func strip(_ rows: [EditorViewModel.MeasurementRow]) -> some View {
        if isCompact {
            // Without fixedSize a long value ("4.00 × 4.00 × 4.00 mm") is
            // compressed and wraps mid-value — see
            // marketing/bugs/iphone-primitive-bar-truncated.png.
            ScrollView(.horizontal, showsIndicators: false) {
                measurements(rows)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        } else {
            measurements(rows)
        }
    }

    private func measurements(_ rows: [EditorViewModel.MeasurementRow]) -> some View {
        HStack(spacing: 20) {
            ForEach(rows) { row in
                HStack(spacing: 6) {
                    Text(row.label)
                        .font(.caption)
                        .foregroundStyle(.barLabel)
                    Text(row.value)
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                }
            }
            if !viewModel.selection.isEmpty || viewModel.isIsolated {
                Divider().frame(height: 16)
                Button {
                    viewModel.toggleIsolateSelection()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: viewModel.isIsolated ? "eye.slash.fill" : "eye.fill")
                        Text(viewModel.isIsolated ? "Show All" : "Isolate")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(viewModel.isIsolated ? Color.orange : Color.blue)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("IsolateSelectionButton")
            }
        }
        .lineLimit(1)
    }
}
