import WebKit

/// Minimal download handler. Saves to ~/Downloads.
final class DownloadHandler: NSObject, WKDownloadDelegate {
    static let shared = DownloadHandler()

    private override init() { super.init() }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        var destination = downloadsDir.appendingPathComponent(suggestedFilename)

        // Avoid overwriting existing files
        var counter = 1
        let name = destination.deletingPathExtension().lastPathComponent
        let ext = destination.pathExtension
        while FileManager.default.fileExists(atPath: destination.path) {
            let newName = ext.isEmpty ? "\(name) (\(counter))" : "\(name) (\(counter)).\(ext)"
            destination = downloadsDir.appendingPathComponent(newName)
            counter += 1
        }

        print("[Download] Saving to: \(destination.path)")
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        print("[Download] Finished")
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        print("[Download] Failed: \(error.localizedDescription)")
    }
}
