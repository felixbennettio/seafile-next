import SwiftUI
import SeafileCore
import UniformTypeIdentifiers
import QuickLook
#if os(macOS)
import AppKit
#endif

struct TransfersView: View {
    let model: AppModel
    @State private var preview: URL?
    @State private var remove: FileTransfer?
    #if os(iOS)
    @State private var export: TransferExport?
    #endif
    var body: some View {
        List {
            #if DEBUG
            if let fixture = model.uiFixture, fixture.slowTransfers {
                Button("Finish fixture downloads") { Task { await fixture.releaseDownloads() } }.accessibilityIdentifier("transfers.fixtureComplete")
            }
            #endif
            if model.transfers.preparingUploads > 0 { ProgressView("Preparing upload files…") }
            if let error = model.transfers.persistenceError { Text("Transfer history could not be saved: \(error)").foregroundStyle(.red) }
            ForEach(Array(model.transfers.transfers.reversed())) { transfer in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(transfer.name, systemImage: transfer.direction == .upload ? "arrow.up.doc" : "arrow.down.doc").font(.headline)
                        Spacer()
                        Text(state(transfer)).foregroundStyle(transfer.state == .failed ? .red : .secondary)
                    }
                    Text((model.accounts.first { $0.id == transfer.accountID }?.name ?? "Account unavailable") + " · " + transfer.path)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if transfer.state == .running {
                        if !transfer.directory, transfer.expectedBytes > 0 {
                            ProgressView(value: Double(min(transfer.bytes, transfer.expectedBytes)), total: Double(transfer.expectedBytes))
                            Text("\(ByteCountFormatter.string(fromByteCount: transfer.bytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: transfer.expectedBytes, countStyle: .file))").font(.caption)
                        } else { ProgressView() }
                    }
                    if let error = transfer.error { Text(error).font(.callout).foregroundStyle(.secondary) }
                    HStack {
                        if transfer.active { Button("Cancel") { model.transfers.cancel(transfer.id) } }
                        else {
                            if transfer.state != .completed { Button("Retry") { do { try model.transfers.retry(transfer.id) } catch { model.errorMessage = error.localizedDescription } } }
                            if let url = model.transfers.localCopy(of: transfer) {
                                if !transfer.directory { Button("Preview") { preview = url } }
                                Button(transfer.direction == .upload ? "Export local copy" : "Save as…") { save(url, name: transfer.name, directory: transfer.directory) }
                            }
                            Button("Remove", role: .destructive) { remove = transfer }
                        }
                    }.buttonStyle(.bordered)
                }.padding(.vertical, 8).accessibilityIdentifier("transfer.\(transfer.name)")
            }
        }.navigationTitle("Transfers")
        // Split-view navigation may retain the old directory view. Invalidate
        // its pending preview even when disappearance is delivered later.
        .onAppear { model.previewGeneration += 1 }
        .overlay { if model.transfers.transfers.isEmpty, model.transfers.preparingUploads == 0 { ContentUnavailableView("No transfers", systemImage: "arrow.up.arrow.down", description: Text("Uploads and downloads continue when you leave their folder.")) } }
        .quickLookPreview($preview)
        .confirmationDialog("Remove this transfer and its local copy?", isPresented: Binding(get: { remove != nil }, set: { if !$0 { remove = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let remove { do { try model.transfers.remove(remove.id) } catch { model.errorMessage = error.localizedDescription } }; remove = nil }
        } message: { Text("The server file is kept. Export an unfinished upload before removing its preserved local copy.") }
        #if os(iOS)
        .sheet(item: $export) { value in TransferExportSheet(url: value.url) }
        #endif
    }
    private func state(_ transfer: FileTransfer) -> String {
        switch transfer.state {
        case .queued: "Queued"
        case .running: transfer.direction == .upload ? "Uploading" : "Downloading"
        case .cancelling: "Cancelling"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
    private func save(_ source: URL, name: String, directory: Bool) {
        #if os(macOS)
        let panel = NSSavePanel(); panel.nameFieldStringValue = name; panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            let access = destination.startAccessingSecurityScopedResource()
            Task {
                defer { if access { destination.stopAccessingSecurityScopedResource() } }
                do { try await TransferExportFiles.copy(source, to: destination, directory: directory) }
                catch { model.errorMessage = error.localizedDescription }
            }
        }
        #else
        export = TransferExport(url: source)
        #endif
    }
}

enum TransferExportFiles {
    /// Prepare the replacement beside its destination, then atomically replace
    /// it; a failed copy must never delete the user's existing file/directory.
    nonisolated static func copy(_ source: URL, to destination: URL, directory: Bool) async throws {
        try await Task.detached(priority: .utility) {
            guard source.standardizedFileURL != destination.standardizedFileURL else { return }
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".seafile-export-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try FileManager.default.copyItem(at: source, to: temporary)
            if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary) }
            else { try FileManager.default.moveItem(at: temporary, to: destination) }
        }.value
    }
}

#if os(iOS)
import UIKit
private struct TransferExport: Identifiable { let id = UUID(); let url: URL }
private struct TransferExportSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController { UIDocumentPickerViewController(forExporting: [url], asCopy: true) }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}
#endif
