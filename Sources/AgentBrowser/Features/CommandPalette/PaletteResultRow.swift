// PaletteResultRow.swift
// A single result row rendered inside CommandPaletteView.

import SwiftUI

struct PaletteResultRow: View {
    let item: PaletteItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Spacing.px8) {
            Image(systemName: item.icon)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(Typography.body)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.px8)
        .frame(height: 36)
        .background(
            isSelected
                ? AnyShapeStyle(Color.accentColor.opacity(0.18))
                : AnyShapeStyle(Color.clear),
            in: .rect(cornerRadius: Radius.small)
        )
        .contentShape(Rectangle())
    }
}
