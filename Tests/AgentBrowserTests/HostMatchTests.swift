import Testing
import Foundation
@testable import AgentBrowser

/// Tests for `BrowserAutomationService.hostMatches(currentURL:requestedDomain:)`.
///
/// Verifies the A4 origin-check used immediately before credential injection:
/// exact match, subdomain match, suffix-but-not-subdomain attack, empty host,
/// IP address as domain, and case insensitivity.
@Suite("HostMatch")
@MainActor
struct HostMatchTests {

    // MARK: - Helpers

    private func url(_ string: String) -> URL {
        URL(string: string)!
    }

    // MARK: - Tests

    @Test("Exact domain match")
    func exactMatch() {
        #expect(BrowserAutomationService.hostMatches(
            currentURL: url("https://google.com/path"),
            requestedDomain: "google.com"
        ))
    }

    @Test("Subdomain match")
    func subdomainMatch() {
        #expect(BrowserAutomationService.hostMatches(
            currentURL: url("https://accounts.google.com/signin"),
            requestedDomain: "google.com"
        ))
    }

    @Test("Suffix-but-not-subdomain is rejected (attack vector)")
    func suffixNotSubdomain() {
        // "google.com.evil.com" ends with ".com" but is NOT a subdomain of "google.com"
        #expect(!BrowserAutomationService.hostMatches(
            currentURL: url("https://google.com.evil.com/"),
            requestedDomain: "google.com"
        ))
    }

    @Test("Unrelated domain is rejected")
    func unrelatedDomain() {
        #expect(!BrowserAutomationService.hostMatches(
            currentURL: url("https://evil.com/"),
            requestedDomain: "google.com"
        ))
    }

    @Test("Empty host returns false")
    func emptyHost() {
        // file:// URLs have no host component
        #expect(!BrowserAutomationService.hostMatches(
            currentURL: url("file:///etc/passwd"),
            requestedDomain: "google.com"
        ))
    }

    @Test("IP address as domain — exact match only")
    func ipAddressExact() {
        #expect(BrowserAutomationService.hostMatches(
            currentURL: url("http://192.168.1.1/admin"),
            requestedDomain: "192.168.1.1"
        ))
    }

    @Test("IP address does not match different IP")
    func ipAddressMismatch() {
        #expect(!BrowserAutomationService.hostMatches(
            currentURL: url("http://192.168.1.2/admin"),
            requestedDomain: "192.168.1.1"
        ))
    }

    @Test("Case insensitive match")
    func caseInsensitive() {
        #expect(BrowserAutomationService.hostMatches(
            currentURL: url("https://ACCOUNTS.GOOGLE.COM/"),
            requestedDomain: "google.com"
        ))
    }

    @Test("Case insensitive requested domain")
    func caseInsensitiveDomain() {
        #expect(BrowserAutomationService.hostMatches(
            currentURL: url("https://accounts.google.com/"),
            requestedDomain: "GOOGLE.COM"
        ))
    }
}
