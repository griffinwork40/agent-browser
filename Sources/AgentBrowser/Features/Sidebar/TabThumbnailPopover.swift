// TabThumbnailPopover.swift
// Hover-preview card shown above a tab row in the sidebar.
// Displays the thumbnail image, tab title, and current URL.

import SwiftUI

/// A self-contained popover card showing a live thumbnail of a browser tab.
///
/// If the thumbnail has not been fetched yet (`thumbnail == nil`) a
/// `ProgressView` spinner is shown instead of the image. Once the async
/// fetch resolves the parent injects the image via the binding.
struct TabThumbnailPopover: View {

    let tab: BrowserTab
    /// The thumbnail to display. Nil while the snapshot is in flight.
    let thumbnail: NSImage?

    // MARK: - Layout constants

    private let cardWidth:  CGFloat = TabThumbnailCache.thumbnailSize.width   // 280
    private let imageHeight: CGFloat = TabThumbnailCache.thumbnailSize.height  // 180

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnailArea
            metaArea
        }
        .frame(width: cardWidth)
        .background(
            RoundedRectangle(cornerRadius: Radius.large)
                .fill(.thickMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: Radius.large))
        .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 4)
    }

    // MARK: - Thumbnail area

    @ViewBuilder
    private var thumbnailArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.large)
                .fill(Color.secondary.opacity(0.15))
                .frame(height: imageHeight)

            if let img = thumbnail {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: cardWidth, height: imageHeight)
                    .clipped()
            } else {
                ProgressView()
                    .scaleEffect(0.8)
                    .frame(width: cardWidth, height: imageHeight)
            }
        }
        .frame(width: cardWidth, height: imageHeight)
        .clipped()
    }

    // MARK: - Meta area (title + URL)

    private var metaArea: some View {
        VStack(alignment: .leading, spacing: Spacing.px2) {
            Text(tab.title)
                .font(Typography.body)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.primary)

            if let url = tab.url {
                Text(url.absoluteString)
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, Spacing.px12)
        .padding(.vertical, Spacing.px8)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Loading state") {
    TabThumbnailPopover(
        tab: {
            let tm = TabManager()
            return tm.createTab(url: URL(string: "https://example.com"))
        }(),
        thumbnail: nil
    )
    .padding(Spacing.px32)
}
#endif
