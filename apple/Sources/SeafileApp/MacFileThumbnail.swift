#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SeafileCore

struct MacFileThumbnail: View {
    var model: AppModel
    let account: ServerAccount
    let repo: Repository
    let entry: DirectoryEntry
    let path: String
    @State private var image: NSImage?
    private static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>(); cache.countLimit = 256; cache.totalCostLimit = 16 * 1024 * 1024; return cache
    }()
    private var key: String { account.id.uuidString + repo.id + path + (entry.objectID ?? String(entry.mtime ?? 0)) }
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: entry.isDirectory ? "folder.fill" : "doc").foregroundStyle(entry.isDirectory ? .blue : .secondary).font(.title3) }
        }.frame(width: 30, height: 30).task(id: key) {
            image = nil
            guard !entry.isDirectory, !repo.encrypted, let type = UTType(filenameExtension: (entry.name as NSString).pathExtension), type.conforms(to: .image) || type.conforms(to: .movie) else { return }
            if let cached = Self.images.object(forKey: key as NSString) { image = cached; return }
            do {
                let data = try await model.client(for: account).thumbnail(repo: repo.id, path: path)
                try Task.checkCancellation()
                if let thumbnail = NSImage(data: data) { Self.images.setObject(thumbnail, forKey: key as NSString, cost: data.count); image = thumbnail }
            } catch { /* Unsupported thumbnails use the normal file icon. */ }
        }
    }
}
#endif
