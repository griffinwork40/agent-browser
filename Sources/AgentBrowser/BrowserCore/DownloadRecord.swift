import Foundation

/// Tracks the state of a single file download.
///
/// `DownloadRecord` is a pure value — it carries no WKDownload reference.
/// The download manager layer maps record IDs to live WKDownload objects.
struct DownloadRecord: Identifiable, Sendable, Hashable {
    let id: UUID
    let sourceURL: URL
    var suggestedFilename: String
    var destinationURL: URL?
    var bytesReceived: Int64
    var totalBytes: Int64?
    var status: DownloadStatus
    let startedAt: Date
    var completedAt: Date?

    init(
        id: UUID = UUID(),
        sourceURL: URL,
        suggestedFilename: String,
        destinationURL: URL? = nil,
        bytesReceived: Int64 = 0,
        totalBytes: Int64? = nil,
        status: DownloadStatus = .downloading,
        startedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.suggestedFilename = suggestedFilename
        self.destinationURL = destinationURL
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    // MARK: - Computed

    /// Download fraction in [0, 1], or nil if total size is unknown.
    var progress: Double? {
        guard let total = totalBytes, total > 0 else { return nil }
        return min(Double(bytesReceived) / Double(total), 1.0)
    }

    /// Human-readable progress string, e.g. "3.2 MB / 10 MB" or "3.2 MB".
    var progressDescription: String {
        let received = ByteCountFormatter.string(fromByteCount: bytesReceived, countStyle: .file)
        if let total = totalBytes {
            let totalStr = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            return "\(received) / \(totalStr)"
        }
        return received
    }

    var isTerminal: Bool {
        switch status {
        case .completed, .failed, .cancelled: return true
        case .downloading, .paused: return false
        }
    }
}

// MARK: - DownloadStatus

enum DownloadStatus: String, Sendable, Codable, Hashable, CaseIterable {
    case downloading
    case paused
    case completed
    case failed
    case cancelled
}
