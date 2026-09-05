// AutomationBridgeLoadingTests.swift
// Regression: automation-bridge-relevance.js extracted from automation-bridge.js.
// Verifies that:
//   1. Both JS files are present in the UserScripts directory.
//   2. The relevance file defines the expected helper names.
//   3. The main bridge delegates to AB._scoreElement, AB._queryMatch,
//      AB._matchesMode, and AB._deduplicateElements (not inline copies).
//   4. The main bridge does NOT define the old inline scoring constants
//      (FOOTER_PATTERNS, BOILERPLATE_PATTERNS) — those belong in the helper.

import Testing
import Foundation

@Suite("AutomationBridgeLoading")
struct AutomationBridgeLoadingTests {

    // Locate the UserScripts directory relative to the source tree.
    // Works in both `swift test` (cwd = package root) and Xcode (cwd = DerivedData).
    private static func userScriptsURL() throws -> URL {
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Sources/AgentBrowser/WebKit/UserScripts"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("../Sources/AgentBrowser/WebKit/UserScripts"),
        ]
        for url in candidates {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                return url
            }
        }
        throw CocoaError(.fileNoSuchFile, userInfo: [
            NSLocalizedDescriptionKey: "UserScripts directory not found from cwd: \(FileManager.default.currentDirectoryPath)"
        ])
    }

    @Test("Both JS files exist in UserScripts")
    func bothFilesExist() throws {
        let dir = try Self.userScriptsURL()
        let relevance = dir.appendingPathComponent("automation-bridge-relevance.js")
        let bridge = dir.appendingPathComponent("automation-bridge.js")
        #expect(FileManager.default.fileExists(atPath: relevance.path),
                "automation-bridge-relevance.js missing from UserScripts")
        #expect(FileManager.default.fileExists(atPath: bridge.path),
                "automation-bridge.js missing from UserScripts")
    }

    @Test("Relevance file exports expected helper names")
    func relevanceFileExportsHelpers() throws {
        let dir = try Self.userScriptsURL()
        let src = try String(contentsOf: dir.appendingPathComponent("automation-bridge-relevance.js"),
                             encoding: .utf8)
        let helpers = ["AB._scoreElement", "AB._queryMatch", "AB._matchesMode", "AB._deduplicateElements"]
        for helper in helpers {
            #expect(src.contains(helper), "relevance file missing: \(helper)")
        }
    }

    @Test("Main bridge delegates to relevance helpers, not inline scoring")
    func mainBridgeDelegatesToHelpers() throws {
        let dir = try Self.userScriptsURL()
        let src = try String(contentsOf: dir.appendingPathComponent("automation-bridge.js"),
                             encoding: .utf8)
        // Must call the helper functions
        #expect(src.contains("AB._scoreElement"), "main bridge must call AB._scoreElement")
        #expect(src.contains("AB._matchesMode"), "main bridge must call AB._matchesMode")
        #expect(src.contains("AB._queryMatch"), "main bridge must call AB._queryMatch")
        #expect(src.contains("AB._deduplicateElements"), "main bridge must call AB._deduplicateElements")
        // Must NOT define the old inline scoring constants (those live in relevance file)
        #expect(!src.contains("const FOOTER_PATTERNS"),
                "main bridge must not define FOOTER_PATTERNS inline (extracted to relevance file)")
        #expect(!src.contains("const BOILERPLATE_PATTERNS"),
                "main bridge must not define BOILERPLATE_PATTERNS inline (extracted to relevance file)")
        #expect(!src.contains("const HIGH_VALUE_ROLES"),
                "main bridge must not define HIGH_VALUE_ROLES inline (extracted to relevance file)")
    }

    @Test("Main bridge does not redefine scoreElement or deduplicateElements functions")
    func mainBridgeNoInlineDuplicates() throws {
        let dir = try Self.userScriptsURL()
        let src = try String(contentsOf: dir.appendingPathComponent("automation-bridge.js"),
                             encoding: .utf8)
        // These function definitions should only be in the relevance file now
        #expect(!src.contains("function scoreElement"), "scoreElement should not be defined in main bridge")
        #expect(!src.contains("function deduplicateElements"), "deduplicateElements should not be defined in main bridge")
        #expect(!src.contains("function matchesMode"), "matchesMode should not be defined in main bridge")
        #expect(!src.contains("function queryMatch"), "queryMatch should not be defined in main bridge")
    }
}
