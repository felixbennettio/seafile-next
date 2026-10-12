#if DEBUG && os(iOS)
import Foundation
@preconcurrency import AVFoundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import SeafileCore

enum MotionPhotoFixture {
    static func photo(to url: URL) throws {
        guard let context = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 256,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let writer = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) else { throw SeafileError.invalidResponse }
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        guard let image = context.makeImage() else { throw SeafileError.invalidResponse }
        CGImageDestinationAddImage(writer, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw SeafileError.invalidResponse }
    }
    static func movie(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 32])
        input.transform = CGAffineTransform(translationX: 32, y: 0).rotated(by: .pi / 2)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 32])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? SeafileError.invalidResponse }; writer.startSession(atSourceTime: .zero)
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        for frame in 0..<12 {
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                guard writer.status == .writing, ContinuousClock.now < deadline else { throw writer.error ?? SeafileError.invalidResponse }
                try await Task.sleep(for: .milliseconds(5))
            }
            var pixel: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel else { throw SeafileError.invalidResponse }
            CVPixelBufferLockBaseAddress(pixel, [])
            guard let base = CVPixelBufferGetBaseAddress(pixel) else { throw SeafileError.invalidResponse }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<32 { for x in 0..<64 {
                let index = y * CVPixelBufferGetBytesPerRow(pixel) + x * 4
                bytes[index] = 255; bytes[index + 1] = frame < 6 ? 255 : 0; bytes[index + 2] = 0; bytes[index + 3] = frame < 6 ? 0 : 255
            } }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 12)) else { throw writer.error ?? SeafileError.invalidResponse }
        }
        input.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? SeafileError.invalidResponse }
    }
    static func merged() async throws -> Data {
        let workspace = try MotionPhotoWorkspace(), folder = workspace.directory
        defer { withExtendedLifetime(workspace) { } }
        let photo = folder.appendingPathComponent("photo.heic"), movie = folder.appendingPathComponent("clip.mov"), merged = folder.appendingPathComponent("motion_MP.heic")
        try self.photo(to: photo); try await self.movie(to: movie)
        try MotionPhotoComposer.compose(photo: photo, video: movie, destination: merged)
        return try Data(contentsOf: merged)
    }
}
#endif
