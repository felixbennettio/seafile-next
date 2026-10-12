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
    @State private var animation: AnimatedImageFrames?
    @State private var player: AVPlayer?
    @State private var motion: PreparedMotionPhoto?
    @State private var error: String?
    @State private var info = false
    @State private var saving = false
    @State private var saved = false
    @State private var registered = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

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
                    else if let image { ZoomableMediaImage(image: image, animation: animation, playing: scenePhase == .active).accessibilityIdentifier("media.image") }
                    else if local != nil || error != nil {
                        VStack(spacing: 12) {
                            Image(systemName: "photo").font(.largeTitle)
                            Text("Preview unavailable")
                            Button("Retry") { Task { await load() } }
                        }.foregroundStyle(.white)
                    }
                    else { ProgressView().tint(.white) }
                }.clipped()
                if motion != nil {
                    Button(player == nil ? "Play motion" : "Show still photo", systemImage: player == nil ? "livephoto.play" : "photo") {
                        if let motion, player == nil { let video = AVPlayer(url: motion.video); player = video; video.play() }
                        else { player?.pause(); player = nil }
                    }.padding(8).disabled(saving).accessibilityIdentifier("media.motion")
                }
                HStack {
                    Button("Previous", systemImage: "chevron.left") { index -= 1 }.disabled(index == 0 || saving).accessibilityIdentifier("media.previous")
                    Spacer()
                    Text("\(index + 1) of \(request.entries.count)").font(.caption).accessibilityIdentifier("media.position")
                    Spacer()
                    Button("Next", systemImage: "chevron.right") { index += 1 }.disabled(index + 1 >= request.entries.count || saving).accessibilityIdentifier("media.next")
                }.padding(12).background(.bar)
            }.navigationTitle(entry.name).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { player?.pause(); player = nil; motion = nil; dismiss() }.disabled(saving).accessibilityIdentifier("media.done") }
                    ToolbarItem(placement: .primaryAction) {
                        Menu("Media actions", systemImage: "ellipsis.circle") {
                            Button("File information", systemImage: "info.circle") { info = true }
                            if let local { ShareLink(item: local) { Label("Share local file", systemImage: "square.and.arrow.up") } }
                            Button("Save to Photos", systemImage: "photo.badge.arrow.down") { saveToPhotos() }.disabled(local == nil || saving)
                            if motion != nil { Button("Save as Live Photo", systemImage: "livephoto") { saveToPhotos(live: true) }.disabled(saving).accessibilityIdentifier("media.saveLive") }
                            Button("Star", systemImage: "star") { star() }
                        }.disabled(saving).accessibilityIdentifier("media.actions")
                    }
                }
                .overlay { if saving { ProgressView("Saving to Photos").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        }.onAppear { if !registered { model.beginFileAction(account); registered = true } }
            .task(id: index) { await load() }
            .onDisappear { player?.pause(); if registered { model.endFileAction(account); registered = false } }
            .onChange(of: scenePhase) { _, phase in if phase != .active { player?.pause() } }
            .interactiveDismissDisabled(saving)
            .sheet(isPresented: $info) { if let local { MediaInformationView(entry: entry, file: local) } }
            .alert("Saved to Photos", isPresented: $saved) { Button("OK", role: .cancel) { } }
    }
    private func load() async {
        player?.pause(); player = nil; motion = nil; image = nil; animation = nil; local = nil; error = nil
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
                if let frames = try await Task.detached(priority: .userInitiated, operation: { try AnimatedImageFrames(file: file) }).value {
                    let first = try await Task.detached(priority: .userInitiated) { try frames.frame(at: 0) }.value
                    try Task.checkCancellation(); guard index == selected else { return }
                    animation = frames; image = UIImage(cgImage: first)
                    return
                }
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
                if ["jpg", "jpeg", "heic", "heif"].contains((name as NSString).pathExtension.lowercased()) {
                    let prepared = try await Task.detached(priority: .userInitiated) {
                        guard let range = try MotionPhotoVideo.inspect(file) else { return Optional<PreparedMotionPhoto>.none }
                        let workspace = try MotionPhotoWorkspace(), movie = workspace.directory.appendingPathComponent("motion." + range.fileExtension)
                        try range.copy(from: file, to: movie)
                        return PreparedMotionPhoto(workspace: workspace, video: movie, presentationTime: range.presentationTime)
                    }.value
                    try Task.checkCancellation(); guard index == selected else { return }
                    if let prepared {
                        let video = AVURLAsset(url: prepared.video)
                        guard try await video.load(.isPlayable), !(try await video.loadTracks(withMediaType: .video)).isEmpty else {
                            throw SeafileError.local("The motion video could not be played. You can still view and share the original photo.")
                        }
                        try Task.checkCancellation(); guard index == selected else { return }
                        motion = prepared
                    }
                }
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
    private func saveToPhotos(live: Bool = false) {
        guard let local, !saving else { return }
        let motion = self.motion
        guard !live || motion != nil else { return }
        let video = Self.isVideo(entry.name)
        saving = true; error = nil
        Task {
            model.beginFileAction(account); defer { saving = false; model.endFileAction(account) }
            do {
                let access = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                guard access == .authorized else { throw SeafileError.local("Allow adding photos in system settings to save this file.") }
                let workspace = live ? try MotionPhotoWorkspace() : nil
                let pair: MotionLivePhotoPair?
                if let workspace, let motion {
                    pair = try await MotionLivePhotoPair.create(photo: local, video: motion.video, directory: workspace.directory, presentationTime: motion.presentationTime)
                    // PhotoKit must accept the actual pair as a Live Photo
                    // before saving; a normal still is never reported as Live.
                    try await validateLivePhoto(pair!)
                } else { pair = nil }
                try await PHPhotoLibrary.shared().performChanges {
                    let asset = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions(); options.shouldMoveFile = false
                    if let pair {
                        asset.addResource(with: .photo, fileURL: pair.photo, options: options)
                        asset.addResource(with: .pairedVideo, fileURL: pair.video, options: options)
                    } else { asset.addResource(with: video ? .video : .photo, fileURL: local, options: options) }
                }
                withExtendedLifetime(workspace) { }
                saved = true
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct PreparedMotionPhoto: Sendable {
    let workspace: MotionPhotoWorkspace
    let video: URL
    let presentationTime: TimeInterval?
}

@MainActor private func validateLivePhoto(_ pair: MotionLivePhotoPair) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let completion = LivePhotoValidation(continuation)
        PHLivePhoto.request(withResourceFileURLs: [pair.photo, pair.video], placeholderImage: nil, targetSize: CGSize(width: 256, height: 256), contentMode: .aspectFit) { photo, info in
            let valid = photo != nil, degraded = info[PHLivePhotoInfoIsDegradedKey] as? Bool == true
            Task { @MainActor in completion.finish(valid: valid, degraded: degraded) }
        }
    }
}

@MainActor private final class LivePhotoValidation {
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func finish(valid: Bool, degraded: Bool) {
        guard !degraded, let continuation else { return }; self.continuation = nil
        if valid { continuation.resume() }
        else { continuation.resume(throwing: SeafileError.local("Photos could not recognize this Live Photo pair. The original file was kept.")) }
    }
}

private struct ZoomableMediaImage: UIViewRepresentable {
    let image: UIImage
    let animation: AnimatedImageFrames?
    let playing: Bool
    func makeUIView(context: Context) -> MediaZoomScrollView { MediaZoomScrollView() }
    func updateUIView(_ view: MediaZoomScrollView, context: Context) { view.set(image, animation: animation, playing: playing) }
    static func dismantleUIView(_ view: MediaZoomScrollView, coordinator: ()) { view.stopAnimation() }
}

private final class MediaZoomScrollView: UIScrollView, UIScrollViewDelegate {
    private let content = UIImageView()
    private var displayed: UIImage?
    private var animation: AnimatedImageFrames?
    private var playing = false
    private var displayLink: CADisplayLink?
    private var elapsed: TimeInterval = 0
    private var timestamp: TimeInterval?
    private var currentFrame = 0
    private var generation = 0
    private var decode: Task<Void, Never>?
    private var decodedFrames = 0
    private var failedAnimation = false
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
    func set(_ image: UIImage, animation: AnimatedImageFrames?, playing: Bool) {
        if displayed !== image || self.animation !== animation {
            stopAnimation(); generation += 1
            self.animation = animation; elapsed = 0; currentFrame = 0; decodedFrames = 0; failedAnimation = false
            displayed = image; setZoomScale(1, animated: false); content.image = image; setNeedsLayout()
        }
        self.playing = playing
        if playing { startAnimation() } else { stopAnimation() }
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopAnimation() } else if playing { startAnimation() }
    }
    private func startAnimation() {
        guard window != nil, displayLink == nil, !failedAnimation, let animation, !animation.timeline.position(at: elapsed).finished else { return }
        let target = MediaAnimationTick(); target.view = self
        let link = CADisplayLink(target: target, selector: #selector(MediaAnimationTick.tick(_:)))
        link.preferredFramesPerSecond = 30; timestamp = nil; displayLink = link
        link.add(to: .main, forMode: .common)
    }
    func stopAnimation() {
        displayLink?.invalidate(); displayLink = nil; timestamp = nil
        decode?.cancel(); decode = nil; generation += 1
    }
    fileprivate func tick(_ link: CADisplayLink) {
        guard let animation else { return }
        if let timestamp { elapsed += max(0, link.timestamp - timestamp) }
        timestamp = link.timestamp
        let position = animation.timeline.position(at: elapsed)
        guard decode == nil else { return }
        if position.frame == currentFrame {
            if position.finished { stopAnimation() }
            return
        }
        let generation = self.generation
        decode = Task { [weak self] in
            do {
                let image = try await Task.detached(priority: .userInitiated) { try animation.frame(at: position.frame) }.value
                try Task.checkCancellation()
                guard let self, self.generation == generation else { return }
                self.content.image = UIImage(cgImage: image); self.currentFrame = position.frame
                self.decodedFrames += 1
                #if DEBUG
                self.content.accessibilityValue = "Animated frames: \(self.decodedFrames)"
                #endif
            } catch {
                guard let self, self.generation == generation else { return }
                // Keep the last displayable frame and original file. A damaged
                // later frame must not trigger a new decode on every display tick.
                self.failedAnimation = true; self.stopAnimation(); return
            }
            guard let self, self.generation == generation else { return }
            self.decode = nil
            if position.finished { self.stopAnimation() }
        }
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

@MainActor private final class MediaAnimationTick: NSObject {
    weak var view: MediaZoomScrollView?
    @objc func tick(_ link: CADisplayLink) { view?.tick(link) }
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
