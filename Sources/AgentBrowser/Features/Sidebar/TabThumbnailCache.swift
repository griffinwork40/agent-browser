// TabThumbnailCache.swift
// LRU thumbnail cache for tab hover previews.
// Snapshots are taken via WKWebView.takeSnapshot and scaled to 280×180 pt.

import AppKit
import WebKit

/// LRU cache of NSImage tab thumbnails, keyed by tab UUID.
///
/// - Capacity: max 20 entries (LRU eviction).
/// - Snapshots are taken only for tabs whose webView has a non-nil URL and
///   is not in an empty/suspended lifecycle (approximated by checking url != nil).
/// - Call `invalidate(tabID:)` whenever a tab navigates to a new URL so the
///   next hover triggers a fresh snapshot.
@MainActor
final class TabThumbnailCache {

    // MARK: - Constants

    static let thumbnailSize = CGSize(width: 280, height: 180)
    private let maxEntries = 20

    // MARK: - LRU Storage

    /// Ordered list of UUIDs, most-recently-used at the end.
    private var lruOrder: [UUID] = []
    private var storage: [UUID: NSImage] = [:]

    // MARK: - In-flight tracking

    /// Prevents duplicate concurrent snapshot tasks for the same tab.
    private var inFlight: Set<UUID> = []

    // MARK: - Public API

    /// Returns a cached thumbnail, or takes a fresh snapshot if needed.
    /// Returns nil immediately if the tab has no loaded URL (empty tab) or
    /// if the snapshot fails.
    func thumbnail(for tab: BrowserTab) async -> NSImage? {
        let id = tab.id

        // Cache hit — promote to MRU and return.
        if let cached = storage[id] {
            promote(id)
            return cached
        }

        // Only snapshot tabs that have an actual page loaded.
        guard tab.url != nil else { return nil }

        // Deduplicate concurrent requests for the same tab.
        guard !inFlight.contains(id) else { return nil }
        inFlight.insert(id)
        defer { inFlight.remove(id) }

        guard let image = await takeSnapshot(of: tab.webView) else { return nil }

        // A navigation may have called invalidate(tabID:) while we were awaiting
        // the snapshot. If the id is no longer in lruOrder it was evicted/invalidated
        // during the async gap — discard the stale image rather than re-inserting it.
        guard lruOrder.contains(id) || storage[id] != nil else { return nil }

        store(id: id, image: image)
        return image
    }

    /// Removes the cached thumbnail for `tabID` so the next hover fetches fresh.
    func invalidate(tabID: UUID) {
        storage.removeValue(forKey: tabID)
        lruOrder.removeAll { $0 == tabID }
    }

    // MARK: - Private: Snapshot

    private func takeSnapshot(of webView: WKWebView) async -> NSImage? {
        // WKSnapshotConfiguration with nil rect = full visible viewport.
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = Self.thumbnailSize.width as NSNumber

        return await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: config) { image, error in
                guard error == nil, let raw = image else {
                    continuation.resume(returning: nil)
                    return
                }
                let scaled = Self.scale(raw, to: Self.thumbnailSize)
                continuation.resume(returning: scaled)
            }
        }
    }

    // MARK: - Private: LRU helpers

    private func store(id: UUID, image: NSImage) {
        if storage[id] != nil {
            promote(id)
        } else {
            // Evict oldest entry if at capacity.
            if lruOrder.count >= maxEntries, let oldest = lruOrder.first {
                lruOrder.removeFirst()
                storage.removeValue(forKey: oldest)
            }
            lruOrder.append(id)
        }
        storage[id] = image
    }

    private func promote(_ id: UUID) {
        lruOrder.removeAll { $0 == id }
        lruOrder.append(id)
    }

    // MARK: - Private: Image scaling

    /// Scales `image` to fit within `targetSize`, letterboxing if needed.
    private static func scale(_ image: NSImage, to targetSize: CGSize) -> NSImage {
        let srcSize = image.size
        guard srcSize.width > 0, srcSize.height > 0 else { return image }

        let widthRatio  = targetSize.width  / srcSize.width
        let heightRatio = targetSize.height / srcSize.height
        let scale = min(widthRatio, heightRatio)
        let newSize = CGSize(width: srcSize.width * scale,
                             height: srcSize.height * scale)

        let result = NSImage(size: targetSize)
        result.lockFocus()
        NSColor.black.withAlphaComponent(0).setFill()
        NSRect(origin: .zero, size: targetSize).fill()

        let drawOrigin = CGPoint(
            x: (targetSize.width  - newSize.width)  / 2,
            y: (targetSize.height - newSize.height) / 2
        )
        image.draw(
            in: NSRect(origin: drawOrigin, size: newSize),
            from: NSRect(origin: .zero, size: srcSize),
            operation: .copy,
            fraction: 1
        )
        result.unlockFocus()
        return result
    }
}
