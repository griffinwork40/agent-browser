// ExtensionListView.swift
// SwiftUI panel listing installed web extensions.
// Shows each extension's name, version, and an enable/disable toggle.
// An "Add Extension…" button opens NSOpenPanel for directory or ZIP selection.

import SwiftUI
import AppKit

struct ExtensionListView: View {

    @State var extensionManager: ExtensionManager

    /// Transient error surfaced while loading.
    @State private var loadError: String?
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            extensionList
            Divider()
            footer
        }
        .frame(minWidth: 360, idealWidth: 420, minHeight: 280)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Extensions")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - List

    @ViewBuilder
    private var extensionList: some View {
        if extensionManager.loadedExtensions.isEmpty {
            emptyState
        } else {
            List(extensionManager.loadedExtensions) { info in
                ExtensionRowView(info: info) { newValue in
                    extensionManager.setEnabled(newValue, forExtensionWithID: info.id)
                } onRemove: {
                    extensionManager.unloadExtension(id: info.id)
                }
            }
            .listStyle(.plain)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No Extensions Installed")
                .font(.headline)
                .foregroundStyle(.primary)
            Text("Click \"Add Extension…\" to install\nan unpacked extension directory or ZIP.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 4) {
            if let error = loadError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .padding(.horizontal, 16)
            }

            HStack {
                if #unavailable(macOS 15.4) {
                    Text("Requires macOS 15.4+")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add Extension…") {
                    pickAndLoad()
                }
                .disabled(!isExtensionsAvailable)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Actions

    private var isExtensionsAvailable: Bool {
        if #available(macOS 15.4, *) { return true }
        return false
    }

    private func pickAndLoad() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.folder, .zip]
        panel.message = "Select an unpacked extension folder or .zip archive"
        panel.prompt = "Add Extension"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            isLoading = true
            loadError = nil
            do {
                try await extensionManager.loadExtension(from: url)
            } catch {
                loadError = error.localizedDescription
            }
            isLoading = false
        }
    }
}

// MARK: - Row

private struct ExtensionRowView: View {
    let info: ExtensionInfo
    let onToggle: (Bool) -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension.fill")
                .foregroundStyle(.blue)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(info.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text("v\(info.version)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { info.isEnabled },
                set: { onToggle($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            Button(role: .destructive) {
                onRemove()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Remove \(info.name)")
        }
        .padding(.vertical, 4)
    }
}
