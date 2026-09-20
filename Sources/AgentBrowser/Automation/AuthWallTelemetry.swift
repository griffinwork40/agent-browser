import Foundation
import Observation

// MARK: - Auth Wall Telemetry
//
// In-memory usage telemetry for automatic auth-wall detection events.
// Tracks how often auth walls are hit, which domains triggered them,
// and whether the human completes auth or abandons.
//
// Not persistent -- counts reset on app restart. Sufficient for Issue #15
// (persistence is a future concern).

// MARK: - Per-Domain Stats

struct AuthWallDomainStats: Sendable {
    /// Number of auth walls detected for this domain.
    var wallsHit: Int = 0
    /// Number of times the human completed authentication.
    var completions: Int = 0
    /// Number of times the human abandoned (humanEnds without completing).
    var abandonments: Int = 0
    /// Timestamp of the most recent wall detection.
    var lastHitAt: Date = Date()
    /// Most recently detected auth status string for this domain.
    var lastStatus: String = ""
}

// MARK: - Telemetry Store

@Observable @MainActor
final class AuthWallTelemetry {

    /// Shared singleton. Owned by the app, injected into the interceptor.
    static let shared = AuthWallTelemetry()

    // MARK: - Counts

    /// Total auth-wall detections across all domains (auto-detection only).
    private(set) var totalWallsHit: Int = 0
    /// Total completions (human finished auth).
    private(set) var totalCompletions: Int = 0
    /// Total abandonments (human gave up).
    private(set) var totalAbandonments: Int = 0

    /// Per-domain breakdown keyed by eTLD+1 (e.g. "github.com").
    private(set) var byDomain: [String: AuthWallDomainStats] = [:]

    // MARK: - Recording

    /// Record a detected auth wall on the given URL.
    /// - Parameters:
    ///   - url: The page URL where the wall was detected.
    ///   - status: Auth status string from `AuthStatusResult.status`.
    func recordWall(url: URL?, status: String) {
        totalWallsHit += 1
        let domain = eTLDPlusOne(url)
        var stats = byDomain[domain] ?? AuthWallDomainStats()
        stats.wallsHit += 1
        stats.lastHitAt = Date()
        stats.lastStatus = status
        byDomain[domain] = stats
    }

    /// Record that the human completed authentication for the given tab URL.
    func recordCompletion(url: URL?) {
        totalCompletions += 1
        let domain = eTLDPlusOne(url)
        var stats = byDomain[domain] ?? AuthWallDomainStats()
        stats.completions += 1
        byDomain[domain] = stats
    }

    /// Record that the human abandoned the auth challenge (closed or navigated away).
    func recordAbandonment(url: URL?) {
        totalAbandonments += 1
        let domain = eTLDPlusOne(url)
        var stats = byDomain[domain] ?? AuthWallDomainStats()
        stats.abandonments += 1
        byDomain[domain] = stats
    }

    // MARK: - Summary

    /// A human-readable one-line summary for debugging.
    var summary: String {
        "AuthWall hits=\(totalWallsHit) completions=\(totalCompletions) "
            + "abandonments=\(totalAbandonments) domains=\(byDomain.count)"
    }

    // MARK: - Private Helpers

    /// Extract a best-effort eTLD+1 from a URL, falling back to the host or "(unknown)".
    private func eTLDPlusOne(_ url: URL?) -> String {
        guard let host = url?.host else { return "(unknown)" }
        // Naive eTLD+1: take the last two dot-separated components.
        let parts = host.split(separator: ".").map(String.init)
        if parts.count >= 2 {
            return parts.suffix(2).joined(separator: ".")
        }
        return host
    }
}
