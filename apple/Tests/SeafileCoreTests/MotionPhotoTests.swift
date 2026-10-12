import Foundation
import Testing
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
@preconcurrency import AVFoundation
@testable import SeafileCore

private func motionDirectory() throws -> URL {
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/mktemp")
    process.arguments = ["-d", FileManager.default.temporaryDirectory.appendingPathComponent("seafile-motion.XXXXXX").path]
    let pipe = Pipe(); process.standardOutput = pipe
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw SeafileError.invalidResponse }
    return URL(fileURLWithPath: String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}
private func bigEndian(_ value: UInt64, bytes: Int) -> Data {
    Data((0..<bytes).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
}
private func box(_ name: String, _ payload: Data, extended: Bool = false) -> Data {
    let header = extended ? bigEndian(1, bytes: 4) + Data(name.utf8) + bigEndian(UInt64(payload.count + 16), bytes: 8)
        : bigEndian(UInt64(payload.count + 8), bytes: 4) + Data(name.utf8)
    return header + payload
}
// These boxes exercise the container reader, not codec playback. Native media
// tests separately create and decode an actual AVFoundation movie.
private func movie(_ brand: String = "mp42") -> Data {
    box("ftyp", Data(brand.utf8) + bigEndian(0, bytes: 4)) + box("moov", Data()) + box("mdat", Data(repeating: 42, count: 17))
}
private func heic(_ video: Data, extended: Bool = false) -> Data {
    box("ftyp", Data("heic".utf8) + bigEndian(0, bytes: 4)) + box("meta", Data(repeating: 0, count: 4)) + box("mpvd", video, extended: extended)
}
private func xmp(_ declaration: String, items: String = "", namespace: String = "http://ns.google.com/photos/1.0/camera/") -> String {
    """
    <x:xmpmeta xmlns:x="adobe:ns:meta/" xmlns:r="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:c="\(namespace)" xmlns:g="http://ns.google.com/photos/1.0/container/" xmlns:i="http://ns.google.com/photos/1.0/container/item/">
    <r:RDF><r:Description \(declaration)>\(items)</r:Description></r:RDF></x:xmpmeta>
    """
}
private func directory(_ length: Int, mime: String = "video/mp4", after: String = "") -> String {
    """
    <g:Directory><r:Seq><r:li><g:Item i:Semantic="Primary" i:Mime="image/jpeg"/></r:li><r:li><g:Item i:Semantic="MotionPhoto" i:Mime="\(mime)" i:Length="\(length)"/></r:li>\(after)</r:Seq></g:Directory>
    """
}
private func jpeg(_ metadata: String, video: Data) -> Data {
    let packet = Data("http://ns.adobe.com/xap/1.0/\0".utf8) + Data(metadata.utf8)
    return Data([0xff,0xd8,0xff,0xe1]) + bigEndian(UInt64(packet.count + 2), bytes: 2) + packet
        + Data([0xff,0xda,0,2,1,2,3,0xff,0xd9]) + video
}

@Test func motionHEICNormalAndExtendedBoxesCopyOnlyMovieAndKeepOriginal() throws {
    let root = try motionDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    for extended in [false, true] {
        let video = movie("qt  "), original = heic(video, extended: extended)
        let source = root.appendingPathComponent("source-\(extended).heic"), destination = root.appendingPathComponent("preview-\(extended).mov")
        try original.write(to: source)
        let range = try #require(try MotionPhotoVideo.inspect(source))
        #expect(range.offset == UInt64(original.count - video.count)); #expect(range.length == UInt64(video.count))
        #expect(range.fileExtension == "mov")
        try range.copy(from: source, to: destination)
        #expect(try Data(contentsOf: destination) == video); #expect(try Data(contentsOf: source) == original)
        #expect((try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(throws: Error.self) { try range.copy(from: source, to: source) }
        #expect(throws: Error.self) { try range.copy(from: source, to: destination) }
        #expect(try Data(contentsOf: destination) == video)
        let link = root.appendingPathComponent("link-\(extended)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        #expect(throws: Error.self) { try range.copy(from: source, to: link) }
        #expect(try Data(contentsOf: destination) == video)
    }
    #expect(throws: Error.self) { try MotionPhotoVideo.inspect(URL(string: "https://example.invalid/photo")!) }
}

@Test func motionJPEGModernMetadataWinsAndLegacyRemainsCompatible() throws {
    let root = try motionDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let video = movie(), file = root.appendingPathComponent("motion.jpg")
    for metadata in [xmp("c:MotionPhoto=\"1\" c:MicroVideo=\"1\" c:MicroVideoOffset=\"999999\"", items: directory(video.count)),
                     xmp("c:MicroVideo=\"1\" c:MicroVideoOffset=\"\(video.count)\""),
                     xmp("", items: "<c:MotionPhoto>1</c:MotionPhoto>" + directory(video.count))] {
        let original = jpeg(metadata, video: video); try original.write(to: file)
        let range = try #require(try MotionPhotoVideo.inspect(file))
        #expect(range.length == UInt64(video.count)); #expect(range.offset == UInt64(original.count - video.count))
        let output = root.appendingPathComponent(UUID().uuidString)
        try range.copy(from: file, to: output); #expect(try Data(contentsOf: output) == video)
    }
}

@Test func motionJPEGRejectsDisabledWrongNamespaceAmbiguousAndExternalMetadata() throws {
    let root = try motionDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let video = movie(), file = root.appendingPathComponent("still.jpg")
    let cases = [
        xmp("c:MotionPhoto=\"0\" c:MicroVideo=\"1\" c:MicroVideoOffset=\"\(video.count)\"", items: directory(video.count)),
        xmp("c:MotionPhoto=\"1\"", items: directory(video.count), namespace: "https://invalid.example/camera"),
        xmp("c:MotionPhoto=\"1\"", items: directory(video.count, mime: "text/plain")),
        xmp("c:MotionPhoto=\"1\"", items: directory(video.count + 99999)),
        xmp("c:MotionPhoto=\"1\"", items: directory(video.count, after: "<r:li><g:Item i:Semantic=\"GainMap\" i:Length=\"2\"/></r:li>")),
        xmp("c:MotionPhoto=\"1\"", items: directory(video.count) + directory(video.count)),
        "<!DOCTYPE x [<!ENTITY probe SYSTEM 'file:///missing-motion-fixture'>]>" + xmp("c:MotionPhoto=\"1\"", items: directory(video.count)),
        xmp("c:MotionPhoto=\"1\" c:MicroVideoOffset=\"\(video.count)\"")
    ]
    for metadata in cases { try jpeg(metadata, video: video).write(to: file); #expect(try MotionPhotoVideo.inspect(file) == nil) }
}

@Test func motionReaderRejectsTruncatedOverflowNonFinalAndFalseSignatureMovies() throws {
    let root = try motionDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let video = movie(), file = root.appendingPathComponent("invalid.heic")
    let prefix = box("ftyp", Data("heic".utf8) + bigEndian(0, bytes: 4))
    let invalid = [heic(video).dropLast(), heic(video) + box("free", Data()),
        prefix + bigEndian(0, bytes: 4) + Data("mpvd".utf8) + video,
        prefix + bigEndian(1, bytes: 4) + Data("mpvd".utf8) + bigEndian(UInt64.max, bytes: 8) + video,
        prefix + box("mpvd", Data("randomftypmp42moovmdat".utf8)),
        heic(box("ftyp", Data("mp42".utf8) + bigEndian(0, bytes: 4)) + box("moov", Data()))]
    for bytes in invalid { try Data(bytes).write(to: file); #expect(try MotionPhotoVideo.inspect(file) == nil) }
}

@Test func motionReaderAndExtractionRespectCancellationBeforeCreatingAFile() async throws {
    let root = try motionDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("motion.heic"), output = root.appendingPathComponent("out.mov")
    try heic(movie()).write(to: file); let range = try #require(try MotionPhotoVideo.inspect(file))
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try range.copy(from: file, to: output)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: output.path))
}

@Test func motionComposerPreservesJPEGAndHEICPixelsMetadataAndMovieBytes() throws {
    let root = try motionDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let video = root.appendingPathComponent("input.mov"), movieBytes = movie("qt  ")
    try movieBytes.write(to: video)
    let context = try #require(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 256,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0.3, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
    for type in [UTType.jpeg, UTType.heic] {
        let photo = root.appendingPathComponent("photo.\(type.preferredFilenameExtension!)"), output = root.appendingPathComponent("merged.\(type.preferredFilenameExtension!)")
        let writer = try #require(CGImageDestinationCreateWithURL(photo as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try #require(context.makeImage()), [kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:01:02 03:04:05"]] as CFDictionary)
        #expect(CGImageDestinationFinalize(writer)); let original = try Data(contentsOf: photo)
        try MotionPhotoComposer.compose(photo: photo, video: video, destination: output)
        let repeated = root.appendingPathComponent("repeat." + type.preferredFilenameExtension!)
        try MotionPhotoComposer.compose(photo: photo, video: video, destination: repeated)
        #expect(try Data(contentsOf: repeated) == Data(contentsOf: output))
        let range = try #require(try MotionPhotoVideo.inspect(output)), extracted = root.appendingPathComponent(UUID().uuidString)
        try range.copy(from: output, to: extracted); #expect(try Data(contentsOf: extracted) == movieBytes)
        let before = try #require(CGImageSourceCreateWithURL(photo as CFURL, nil)), after = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect(CGImageSourceGetType(before) == CGImageSourceGetType(after))
        let beforePixels = try #require(CGImageSourceCreateImageAtIndex(before, 0, nil)).dataProvider?.data
        let afterPixels = try #require(CGImageSourceCreateImageAtIndex(after, 0, nil)).dataProvider?.data
        #expect(beforePixels == afterPixels)
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(after, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyOrientation] as? Int == 6)
        #expect((properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:01:02 03:04:05")
        #expect(try Data(contentsOf: photo) == original); #expect(try Data(contentsOf: video) == movieBytes)
        #expect(throws: Error.self) { try MotionPhotoComposer.compose(photo: photo, video: video, destination: output) }
        #expect(try MotionPhotoVideo.inspect(output) == range)
    }
}

private func actualMotionMovie(_ url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 32])
    input.transform = CGAffineTransform(translationX: 32, y: 0).rotated(by: .pi / 2)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 32])
    writer.add(input); #expect(writer.startWriting()); writer.startSession(atSourceTime: .zero)
    let deadline = ContinuousClock.now.advanced(by: .seconds(20))
    for frame in 0..<12 {
        while !input.isReadyForMoreMediaData {
            guard ContinuousClock.now < deadline, writer.status == .writing else { throw writer.error ?? SeafileError.invalidResponse }
            try await Task.sleep(for: .milliseconds(5))
        }
        var pixel: CVPixelBuffer?
        #expect(CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &pixel) == kCVReturnSuccess)
        let buffer = try #require(pixel); CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        for y in 0..<32 { for x in 0..<64 {
            let index = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
            bytes[index] = 255; bytes[index + 1] = frame < 6 ? 255 : 0; bytes[index + 2] = 0; bytes[index + 3] = frame < 6 ? 0 : 255
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 12)))
    }
    input.markAsFinished(); await writer.finishWriting(); #expect(writer.status == .completed)
}

@Test func motionLivePairContainsPlayableVideoMatchingIdentifiersAndActualTimedStillMetadata() async throws {
    let root = try motionDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let input = root.appendingPathComponent("original.mov"); try await actualMotionMovie(input)
    let context = try #require(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 256,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let photo = root.appendingPathComponent("still.jpg"), output = try #require(CGImageDestinationCreateWithURL(photo as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
    CGImageDestinationAddImage(output, try #require(context.makeImage()), [kCGImagePropertyOrientation: 6] as CFDictionary); #expect(CGImageDestinationFinalize(output))
    let originalPhoto = try Data(contentsOf: photo), originalVideo = try Data(contentsOf: input)
    let pair = try await MotionLivePhotoPair.create(photo: photo, video: input, directory: root, presentationTime: 0.25)
    let stillSource = try #require(CGImageSourceCreateWithURL(pair.photo as CFURL, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(stillSource, 0, nil) as? [CFString: Any])
    #expect((properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any])?["17"] as? String == pair.identifier)
    #expect(properties[kCGImagePropertyOrientation] as? Int == 6)
    let asset = AVURLAsset(url: pair.video); #expect(try await asset.load(.isPlayable))
    let content = try await asset.load(.metadata).first { $0.identifier == .quickTimeMetadataContentIdentifier }
    #expect(try await content?.load(.stringValue) == pair.identifier)
    let inputTrack = try #require(try await AVURLAsset(url: input).loadTracks(withMediaType: .video).first)
    let outputTrack = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let inputTransform = try await inputTrack.load(.preferredTransform), outputTransform = try await outputTrack.load(.preferredTransform)
    #expect(inputTransform == outputTransform)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    let first = try await generator.image(at: CMTime(value: 1, timescale: 12)), last = try await generator.image(at: CMTime(value: 10, timescale: 12))
    #expect(first.image.dataProvider?.data != last.image.dataProvider?.data)
    let metadataTrack = try #require(try await asset.loadTracks(withMediaType: .metadata).first)
    let reader = try AVAssetReader(asset: asset), trackOutput = AVAssetReaderTrackOutput(track: metadataTrack, outputSettings: nil)
    reader.add(trackOutput); let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: trackOutput)
    #expect(reader.startReading()); let group = try #require(adaptor.nextTimedMetadataGroup())
    let outputDuration = try await asset.load(.duration)
    #expect(group.timeRange.start.seconds > 0 && group.timeRange.start.seconds < outputDuration.seconds)
    #expect(abs(group.timeRange.start.seconds - 0.25) < 0.002)
    #expect(group.items.first?.identifier?.rawValue == "mdta/com.apple.quicktime.still-image-time")
    #expect(try await group.items.first?.load(.numberValue) == 0)
    #expect(try Data(contentsOf: photo) == originalPhoto); #expect(try Data(contentsOf: input) == originalVideo)
    let heic = root.appendingPathComponent("still.heic"), heicOutput = try #require(CGImageDestinationCreateWithURL(heic as CFURL, UTType.heic.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(heicOutput, try #require(context.makeImage()), [kCGImagePropertyOrientation: 6] as CFDictionary)
    #expect(CGImageDestinationFinalize(heicOutput)); let heicOriginal = try Data(contentsOf: heic)
    let heicPair = try await MotionLivePhotoPair.create(photo: heic, video: input, directory: root)
    let heicSource = try #require(CGImageSourceCreateWithURL(heicPair.photo as CFURL, nil))
    let heicProperties = try #require(CGImageSourceCopyPropertiesAtIndex(heicSource, 0, nil) as? [CFString: Any])
    #expect((heicProperties[kCGImagePropertyMakerAppleDictionary] as? [String: Any])?["17"] as? String == heicPair.identifier)
    #expect(CGImageSourceGetType(heicSource) as String? == UTType.heic.identifier)
    #expect(try Data(contentsOf: heic) == heicOriginal)
}

@Test func motionLegacyTrailersStayOutsideImagePixelsAndHonorDisabledUUIDMetadata() throws {
    let root = try motionDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("legacy.jpg"), video = movie()
    let jpegImage = Data([0xff,0xd8,0xff,0xda,0,2,1,2,0xff,0,3,0xff,0xd9])
    try (jpegImage + video).write(to: file)
    #expect(try MotionPhotoVideo.inspect(file)?.offset == UInt64(jpegImage.count))
    let comment = Data("not a movie ftypmp42 moovmdat".utf8)
    try (Data([0xff,0xd8,0xff,0xfe]) + bigEndian(UInt64(comment.count + 2), bytes: 2) + comment + Data([0xff,0xd9])).write(to: file)
    #expect(try MotionPhotoVideo.inspect(file) == nil)
    let isoImage = box("ftyp", Data("heic".utf8) + bigEndian(0, bytes: 4)) + box("meta", Data(repeating: 0, count: 4)) + box("mdat", Data(repeating: 42, count: 4))
    try (isoImage + video).write(to: file)
    #expect(try MotionPhotoVideo.inspect(file)?.offset == UInt64(isoImage.count))
    let uuid = Data([0xbe,0x7a,0xcf,0xcb,0x97,0xa9,0x42,0xe8,0x9c,0x71,0x99,0x94,0x91,0xe3,0xaf,0xac])
    for enabled in [0,1] {
        let metadata = xmp("c:MotionPhoto=\"\(enabled)\" c:MotionPhotoPresentationTimestampUs=\"250000\"", items: directory(video.count))
        try (isoImage + box("uuid", uuid + Data(metadata.utf8)) + box("mpvd", video)).write(to: file)
        let range = try MotionPhotoVideo.inspect(file)
        #expect((range != nil) == (enabled == 1))
        if enabled == 1 { #expect(range?.presentationTime == 0.25) }
    }
}

@Test @MainActor func motionBackupKeepsSeparateOrMergedRecordsAfterSwitchingAndRelaunching() throws {
    let root = try motionDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let account = UUID(), primary = "1:IMG_0001.heic", paired = "9:IMG_0001.mov", digest = String(repeating: "a", count: 64)
    var settings = PhotoBackupSettings(repository: "repo", path: "/")
    settings.mergeLivePhotos = true
    var store: PhotoBackupHistory? = try PhotoBackupHistory(root: root)
    try store!.configure(account: account, settings: settings)
    #expect(try store!.useMergedLivePhoto(account: account, settings: settings, asset: "new", revision: "1", primary: primary, paired: paired))
    let pending = PhotoBackupRecord(accountID: account, repository: "repo", path: "/", asset: "pending", revision: "1",
        resource: primary, filename: "raw.heic", digest: digest, size: 17)
    try store!.prepare(pending)
    #expect(try !store!.useMergedLivePhoto(account: account, settings: settings, asset: "pending", revision: "1", primary: primary, paired: paired))
    let merged = PhotoBackupRecord(accountID: account, repository: "repo", path: "/", asset: "merged", revision: "1",
        resource: PhotoBackupFiles.motionResource(primary: primary, paired: paired), filename: "merged_MP.heic", digest: digest, size: 100)
    try store!.prepare(merged); try store!.confirm(merged.id, digest: digest, size: 100)
    settings.mergeLivePhotos = false; settings.includeLivePhotoVideo = false
    try store!.configure(account: account, settings: settings); store = nil
    let reopened = try PhotoBackupHistory(root: root)
    #expect(try reopened.useMergedLivePhoto(account: account, settings: settings, asset: "merged", revision: "1", primary: primary, paired: paired))
    #expect(try !reopened.useMergedLivePhoto(account: account, settings: settings, asset: "pending", revision: "1", primary: primary, paired: paired))
    #expect(try reopened.record(pending.id)?.completed == false)
    #expect(try reopened.record(merged.id)?.completed == true)
    let filename = try PhotoBackupFiles.motionFilename(original: String(repeating: "p", count: 244) + ".heic", asset: "fixture", digest: digest)
    #expect(filename.hasSuffix("MP.heic")); #expect(filename.utf8.count <= 255)
    let old = Data(#"{"repository":"repo","path":"/","includeLivePhotoVideo":true}"#.utf8)
    #expect(try JSONDecoder().decode(PhotoBackupSettings.self, from: old).mergeLivePhotos == false)
}
