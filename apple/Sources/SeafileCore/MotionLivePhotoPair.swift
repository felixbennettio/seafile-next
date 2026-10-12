import Foundation
@preconcurrency import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// A private pair prepared for PhotoKit. Creating it never edits the original
/// motion photo. The caller keeps its owned directory until PhotoKit finishes.
public struct MotionLivePhotoPair: Sendable {
    public let photo: URL, video: URL, identifier: String

    public static func create(photo source: URL, video movie: URL, directory: URL, presentationTime: TimeInterval? = nil) async throws -> Self {
        try Task.checkCancellation()
        guard source.isFileURL, movie.isFileURL, directory.isFileURL,
              let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { throw SeafileError.invalidResponse }
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration)
        guard try await asset.load(.isPlayable), duration.isNumeric, duration.seconds > 0,
              duration.seconds.isFinite else { throw SeafileError.local("This motion photo's video cannot be played.") }
        let identifier = UUID().uuidString
        let image = try await Task.detached(priority: .userInitiated) {
            try writePhoto(source, identifier: identifier, directory: directory)
        }.value
        let video = directory.appendingPathComponent(identifier + ".mov")
        do {
            try Task.checkCancellation()
            try await writeMovie(asset, destination: video, identifier: identifier, duration: duration, presentationTime: presentationTime)
            return Self(photo: image, video: video, identifier: identifier)
        } catch {
            try? FileManager.default.removeItem(at: image); try? FileManager.default.removeItem(at: video)
            throw error
        }
    }

    private static func writePhoto(_ source: URL, identifier: String, directory: URL) throws -> URL {
        try Task.checkCancellation()
        guard let input = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(input),
              [UTType.jpeg.identifier, UTType.heic.identifier, UTType.heif.identifier].contains(type as String) else { throw SeafileError.invalidResponse }
        let destination = directory.appendingPathComponent(identifier + (type as String == UTType.jpeg.identifier ? ".jpg" : ".heic"))
        let output = try MotionPhotoOutput(destination)
        var finished = false
        defer { try? output.handle.close(); if !finished { try? FileManager.default.removeItem(at: destination) } }
        guard let consumer = output.consumer(), let writer = CGImageDestinationCreateWithDataConsumer(consumer, type, 1, nil) else { throw SeafileError.invalidResponse }
        var properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any] ?? [:]
        var maker = properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any] ?? [:]
        maker["17"] = identifier; properties[kCGImagePropertyMakerAppleDictionary] = maker
        CGImageDestinationAddImageFromSource(writer, input, 0, properties as CFDictionary)
        // Preserve public auxiliary image data when preparing the paired still.
        for kind in [kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypePortraitEffectsMatte, kCGImageAuxiliaryDataTypeHDRGainMap] {
            if let data = CGImageSourceCopyAuxiliaryDataInfoAtIndex(input, 0, kind) { CGImageDestinationAddAuxiliaryDataInfo(writer, kind, data) }
        }
        guard CGImageDestinationFinalize(writer), !output.failed else { throw SeafileError.invalidResponse }
        try output.handle.synchronize(); try Task.checkCancellation()
        guard let result = CGImageSourceCreateWithURL(destination as CFURL, nil),
              let info = CGImageSourceCopyPropertiesAtIndex(result, 0, nil) as? [CFString: Any],
              (info[kCGImagePropertyMakerAppleDictionary] as? [String: Any])?["17"] as? String == identifier else {
            throw SeafileError.local("The Live Photo identifier could not be written. The original photo is preserved.")
        }
        finished = true; return destination
    }

    private static func writeMovie(_ asset: AVURLAsset, destination: URL, identifier: String, duration: CMTime, presentationTime: TimeInterval?) async throws {
        let tracks = try await asset.load(.tracks).filter { $0.mediaType == .video || $0.mediaType == .audio }
        guard tracks.contains(where: { $0.mediaType == .video }), !FileManager.default.fileExists(atPath: destination.path) else { throw SeafileError.invalidResponse }
        let reader = try AVAssetReader(asset: asset), writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        var channels: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        for track in tracks {
            guard let format = try await track.load(.formatDescriptions).first else { throw SeafileError.invalidResponse }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil); output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            if track.mediaType == .video { input.transform = try await track.load(.preferredTransform) }
            guard reader.canAdd(output), writer.canAdd(input) else { throw SeafileError.invalidResponse }
            reader.add(output); writer.add(input); channels.append((output, input))
        }
        let content = AVMutableMetadataItem(); content.identifier = .quickTimeMetadataContentIdentifier
        content.value = identifier as NSString; content.dataType = kCMMetadataBaseDataType_UTF8 as String
        writer.metadata = [content]
        let key = "mdta/com.apple.quicktime.still-image-time"
        var description: CMFormatDescription?
        let specification = [kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: key,
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8 as String]
        guard CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [specification] as CFArray, formatDescriptionOut: &description) == noErr, let description else { throw SeafileError.invalidResponse }
        let metadata = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: description)
        metadata.expectsMediaDataInRealTime = false
        guard writer.canAdd(metadata) else { throw SeafileError.invalidResponse }; writer.add(metadata)
        let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadata)
        guard reader.startReading(), writer.startWriting() else { throw writer.error ?? reader.error ?? SeafileError.invalidResponse }
        var finished = false
        defer { if !finished { reader.cancelReading(); writer.cancelWriting() } }
        writer.startSession(atSourceTime: .zero)
        let still = AVMutableMetadataItem(); still.identifier = AVMetadataIdentifier(rawValue: key)
        still.value = NSNumber(value: Int8(0)); still.dataType = kCMMetadataBaseDataType_SInt8 as String
        let stillTime = presentationTime.flatMap { $0.isFinite && $0 >= 0 && $0 < duration.seconds ? $0 : nil } ?? duration.seconds / 2
        let instant = CMTime(seconds: stillTime, preferredTimescale: 60000)
        let frame = CMTime(seconds: min(1 / 30, duration.seconds / 2), preferredTimescale: 60000)
        let group = AVTimedMetadataGroup(items: [still], timeRange: CMTimeRange(start: instant, duration: frame))
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while !metadata.isReadyForMoreMediaData {
            try Task.checkCancellation(); guard writer.status == .writing, ContinuousClock.now < deadline else { throw writer.error ?? SeafileError.invalidResponse }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard adaptor.append(group) else { throw writer.error ?? SeafileError.invalidResponse }; metadata.markAsFinished()
        var active = Set(channels.indices)
        while !active.isEmpty {
            try Task.checkCancellation()
            guard writer.status == .writing, reader.status != .failed, ContinuousClock.now < deadline else { throw writer.error ?? reader.error ?? SeafileError.invalidResponse }
            var progressed = false
            for index in Array(active) {
                let (output, input) = channels[index]
                guard input.isReadyForMoreMediaData else { continue }
                // Interleave tracks so audio cannot fill a muxer's buffers
                // while it waits for video, or conversely.
                if let sample = output.copyNextSampleBuffer() {
                    guard input.append(sample) else { throw writer.error ?? SeafileError.invalidResponse }
                } else { input.markAsFinished(); active.remove(index) }
                progressed = true
            }
            if !progressed { try await Task.sleep(for: .milliseconds(5)) }
        }
        guard reader.status == .completed else { throw reader.error ?? SeafileError.invalidResponse }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? SeafileError.invalidResponse }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        try Task.checkCancellation(); finished = true
    }
}
