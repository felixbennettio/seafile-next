#if os(iOS)
import SwiftUI
import AVKit
import Photos
import ImageIO
import SeafileCore

struct MobileMediaRequest: Identifiable {
    let id = UUID()
    let entries: [DirectoryEntry]
    let parent: String
    let initial: String
}

struct MobileMediaView: View {
    let model: AppModel
    let account: ServerAccount
    let repository: Repository
    let request: MobileMediaRequest
    @State private var index = 0
    @State private var local: URL?
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var error: String?
    @State private var info = false
    @State private var saving = false
    @State private var saved = false
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, account: ServerAccount, repository: Repository, request: MobileMediaRequest) {
        self.model = model; self.account = account; self.repository = repository; self.request = request
        _index = State(initialValue: request.entries.firstIndex { $0.name == request.initial } ?? 0)
    }

    static func isVideo(_ name: String) -> Bool { ["mp4", "m4v", "mov"].contains((name as NSString).pathExtension.lowercased()) }
    static func supports(_ name: String) -> Bool {
        isVideo(name) || ["jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp"].contains((name as NSString).pathExtension.lowercased())
    }
    private var entry: DirectoryEntry { request.entries[index] }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error { Text(error).font(.callout).foregroundStyle(.secondary).padding().accessibilityIdentifier("media.error") }
                ZStack {
                    Color.black
                    if let player { VideoPlayer(player: player).accessibilityIdentifier("media.video") }
                    else if let image { ZoomableMediaImage(image: image).accessibilityIdentifier("media.image") }
                    else if local != nil || error != nil {
                        VStack(spacing: 12) {
                            Image(systemName: "photo").font(.largeTitle)
                            Text("Preview unavailable")
                            Button("Retry") { Task { await load() } }
                        }.foregroundStyle(.white)
                    }
                    else { ProgressView().tint(.white) }
                }.clipped()
                HStack {
                    Button("Previous", systemImage: "chevron.left") { index -= 1 }.disabled(index == 0 || saving).accessibilityIdentifier("media.previous")
                    Spacer()
                    Text("\(index + 1) of \(request.entries.count)").font(.caption).accessibilityIdentifier("media.position")
                    Spacer()
                    Button("Next", systemImage: "chevron.right") { index += 1 }.disabled(index + 1 >= request.entries.count || saving).accessibilityIdentifier("media.next")
                }.padding(12).background(.bar)
            }.navigationTitle(entry.name).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.disabled(saving).accessibilityIdentifier("media.done") }
                    ToolbarItem(placement: .primaryAction) {
                        Menu("Media actions", systemImage: "ellipsis.circle") {
                            Button("File information", systemImage: "info.circle") { info = true }
                            if let local { ShareLink(item: local) { Label("Share local file", systemImage: "square.and.arrow.up") } }
                            Button("Save to Photos", systemImage: "photo.badge.arrow.down") { saveToPhotos() }.disabled(local == nil || saving)
                            Button("Star", systemImage: "star") { star() }
                        }.disabled(saving).accessibilityIdentifier("media.actions")
                    }
                }
                .overlay { if saving { ProgressView("Saving to Photos").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        }.task(id: index) { await load() }
            .onDisappear { player?.pause() }
            .sheet(isPresented: $info) { if let local { MediaInformationView(entry: entry, file: local) } }
            .alert("Saved to Photos", isPresented: $saved) { Button("OK", role: .cancel) { } }
    }
    private func load() async {
        player?.pause(); player = nil; image = nil; local = nil; error = nil
        let selected = index, path = entry.path(in: request.parent), name = entry.name
        do {
            let id = try model.transfers.enqueueDownload(accountID: account.id, repository: repository.id, path: path)
            let file: URL
            do { file = try await model.transfers.result(for: id) }
            catch is CancellationError { throw CancellationError() }
            catch {
                guard let cached = model.transfers.cachedDownload(accountID: account.id, repository: repository.id, path: path) else { throw error }
                file = cached; self.error = "Showing the cached copy. " + error.localizedDescription
            }
            try Task.checkCancellation(); guard index == selected else { return }
            local = file
            if Self.isVideo(name) { player = AVPlayer(url: file) }
            else {
                // Decode a bounded display image rather than expanding every
                // original image in memory. The downloaded original is retained.
                guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                      let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 4096,
                        kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                    throw SeafileError.local("This image format could not be displayed. You can still share the original file.")
                }
                image = UIImage(cgImage: decoded)
            }
        } catch is CancellationError { }
        catch { if !Task.isCancelled, index == selected { self.error = error.localizedDescription } }
    }
    private func star() {
        let path = entry.path(in: request.parent)
        Task {
            model.beginFileAction(account); defer { model.endFileAction(account) }
            do { try await model.client(for: account).setStarred(repo: repository.id, path: path, starred: true) }
            catch { self.error = error.localizedDescription }
        }
    }
    private func saveToPhotos() {
        guard let local, !saving else { return }
        let video = Self.isVideo(entry.name)
        saving = true; error = nil
        Task {
            model.beginFileAction(account); defer { saving = false; model.endFileAction(account) }
            do {
                let access = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                guard access == .authorized else { throw SeafileError.local("Allow adding photos in system settings to save this file.") }
                try await PHPhotoLibrary.shared().performChanges {
                    let asset = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions(); options.shouldMoveFile = false
                    asset.addResource(with: video ? .video : .photo, fileURL: local, options: options)
                }
                saved = true
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct ZoomableMediaImage: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> MediaZoomScrollView { MediaZoomScrollView() }
    func updateUIView(_ view: MediaZoomScrollView, context: Context) { view.set(image) }
}

private final class MediaZoomScrollView: UIScrollView, UIScrollViewDelegate {
    private let content = UIImageView()
    private var displayed: UIImage?
    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self; minimumZoomScale = 1; maximumZoomScale = 5
        showsVerticalScrollIndicator = false; showsHorizontalScrollIndicator = false
        backgroundColor = .black
        content.contentMode = .scaleAspectFit; addSubview(content)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:))); doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        content.isAccessibilityElement = true; content.accessibilityLabel = "Photo"; content.accessibilityIdentifier = "media.photo"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func set(_ image: UIImage) {
        guard displayed !== image else { return }
        displayed = image; setZoomScale(1, animated: false); content.image = image; setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale == 1 { content.frame = CGRect(origin: .zero, size: bounds.size); contentSize = bounds.size }
        content.center = CGPoint(x: max(bounds.width, contentSize.width) / 2, y: max(bounds.height, contentSize.height) / 2)
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }
    @objc private func toggleZoom(_ tap: UITapGestureRecognizer) {
        if zoomScale > 1 { setZoomScale(1, animated: true) }
        else { let p = tap.location(in: content); zoom(to: CGRect(x: p.x - bounds.width / 4, y: p.y - bounds.height / 4, width: bounds.width / 2, height: bounds.height / 2), animated: true) }
    }
}

private struct MediaInformationView: View {
    let entry: DirectoryEntry
    let file: URL
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Name", value: entry.name)
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0), countStyle: .file))
                if let date = entry.mtime { LabeledContent("Last modified", value: Date(timeIntervalSince1970: date).formatted()) }
                if let source = CGImageSourceCreateWithURL(file as CFURL, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                    if let w = properties[kCGImagePropertyPixelWidth] as? Int, let h = properties[kCGImagePropertyPixelHeight] as? Int { LabeledContent("Dimensions", value: "\(w) × \(h)") }
                    if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any], let model = tiff[kCGImagePropertyTIFFModel] as? String { LabeledContent("Camera", value: model) }
                    if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any], let taken = exif[kCGImagePropertyExifDateTimeOriginal] as? String { LabeledContent("Taken", value: taken) }
                }
            }.navigationTitle("File information").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
#endif
