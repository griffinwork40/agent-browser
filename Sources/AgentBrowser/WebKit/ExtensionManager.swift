import Foundation
import WebKit
import Observation

// MARK: - Error types

enum ExtensionManagerError: LocalizedError {
    case unavailableOnThisOSVersion
    case invalidExtensionBundle(URL)
    case extensionAlreadyLoaded(String)

    var errorDescription: String? {
        switch self {
        case .unavailableOnThisOSVersion:
            return "Web extensions require macOS 15.4 or later."
        case .invalidExtensionBundle(let url):
            return "'\(url.lastPathComponent)' is not a valid web extension bundle."
        case .extensionAlreadyLoaded(let id):
            return "Extension '\(id)' is already loaded."
        }
    }
}

// MARK: - ExtensionManager

/// Manages web extensions for the entire browser process.
///
/// ``WKWebExtensionController`` requires macOS 15.4+. On macOS 14 all
/// mutating methods are silent no-ops and ``loadedExtensions`` stays empty.
/// Callers never crash: all WebKit extension APIs are guarded with
/// `#available(macOS 15.4, *)`.
///
/// Extensions live in:
/// `~/Library/Application Support/AgentBrowser/Extensions/`
@Observable @MainActor
final class ExtensionManager {

    // MARK: - Public state

    /// All currently-tracked extensions (enabled or disabled).
    /// `internal` set is intentional: tests use `@testable import` to inject
    /// fake entries via ``_testInject(_:)`` without requiring a real bundle.
    private(set) var loadedExtensions: [ExtensionInfo] = []

    // MARK: - Test support

    /// Injects an `ExtensionInfo` directly, bypassing real `WKWebExtension` APIs.
    /// **For use by unit tests only.** Exposed at `internal` access so
    /// `@testable import AgentBrowser` reaches it without public surface bloat.
    @MainActor
    func _testInject(_ info: ExtensionInfo) {
        loadedExtensions.append(info)
    }

    // MARK: - Private storage

    /// Typed `Any?` so the property declaration compiles on macOS 14.
    private var _controllerStorage: Any?

    /// Maps extension id → `WKWebExtensionContext` (erased to `Any`).
    private var _contextStorage: [String: Any] = [:]

    // MARK: - Directory

    /// Root directory where extensions are installed.
    let extensionsDirectory: URL

    // MARK: - Init

    init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        extensionsDirectory = appSupport
            .appendingPathComponent("AgentBrowser/Extensions", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: extensionsDirectory,
            withIntermediateDirectories: true
        )
        setupController()
    }

    // MARK: - Controller accessor

    /// The shared `WKWebExtensionController` on macOS 15.4+; `nil` on older OS.
    @available(macOS 15.4, *)
    var extensionController: WKWebExtensionController? {
        _controllerStorage as? WKWebExtensionController
    }

    // MARK: - Load

    /// Load a web extension from an unpacked directory or ZIP archive.
    ///
    /// Throws ``ExtensionManagerError/unavailableOnThisOSVersion`` on macOS < 15.4.
    func loadExtension(from url: URL) async throws {
        guard #available(macOS 15.4, *) else {
            throw ExtensionManagerError.unavailableOnThisOSVersion
        }
        guard let controller = extensionController else {
            throw ExtensionManagerError.unavailableOnThisOSVersion
        }

        let ext: WKWebExtension
        do {
            ext = try await WKWebExtension(resourceBaseURL: url)
        } catch {
            throw ExtensionManagerError.invalidExtensionBundle(url)
        }

        let info = makeInfo(from: ext, url: url)
        guard !loadedExtensions.contains(where: { $0.id == info.id }) else {
            throw ExtensionManagerError.extensionAlreadyLoaded(info.id)
        }

        let context = WKWebExtensionContext(for: ext)
        try controller.load(context)

        _contextStorage[info.id] = context
        loadedExtensions.append(info)
    }

    // MARK: - Unload

    /// Remove a loaded extension by its identifier. Silent no-op on macOS 14.
    func unloadExtension(id: String) {
        guard #available(macOS 15.4, *),
              let controller = extensionController else { return }

        if let ctx = _contextStorage[id] as? WKWebExtensionContext {
            try? controller.unload(ctx)
            _contextStorage.removeValue(forKey: id)
        }
        loadedExtensions.removeAll { $0.id == id }
    }

    // MARK: - Enable / Disable

    /// Toggle the ``ExtensionInfo/isEnabled`` state.
    ///
    /// - Disabling unloads the context from the controller (extension stops
    ///   running) but keeps the `ExtensionInfo` in ``loadedExtensions``.
    /// - Enabling re-loads the stored context so the extension resumes.
    ///
    /// Silent no-op on macOS 14.
    func setEnabled(_ enabled: Bool, forExtensionWithID id: String) {
        guard #available(macOS 15.4, *),
              let controller = extensionController,
              let index = loadedExtensions.firstIndex(where: { $0.id == id }) else { return }

        let wasEnabled = loadedExtensions[index].isEnabled
        guard wasEnabled != enabled else { return }
        loadedExtensions[index].isEnabled = enabled

        if let ctx = _contextStorage[id] as? WKWebExtensionContext {
            if enabled {
                try? controller.load(ctx)
            } else {
                try? controller.unload(ctx)
            }
        }
    }

    // MARK: - Private helpers

    private func setupController() {
        guard #available(macOS 15.4, *) else { return }
        _controllerStorage = WKWebExtensionController()
    }

    @available(macOS 15.4, *)
    private func makeInfo(from ext: WKWebExtension, url: URL) -> ExtensionInfo {
        // Prefer manifest-declared id via browser_specific_settings.gecko.id,
        // then fall back to the directory name (minus extension).
        let manifest = ext.manifest
        let geckoID = (manifest["browser_specific_settings"] as? [String: Any])
            .flatMap { $0["gecko"] as? [String: Any] }
            .flatMap { $0["id"] as? String }
        let id = geckoID
            ?? (manifest["id"] as? String)
            ?? url.deletingPathExtension().lastPathComponent

        let name    = ext.displayName    ?? (manifest["name"] as? String) ?? url.lastPathComponent
        let version = ext.version        ?? (manifest["version"] as? String) ?? "0.0"

        return ExtensionInfo(
            id: id,
            name: name,
            version: version,
            isEnabled: true,
            extensionURL: url
        )
    }
}
