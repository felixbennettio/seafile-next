import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import SeafileCore

private func animationTestDirectory() throws -> URL {
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/mktemp")
    process.arguments = ["-d", FileManager.default.temporaryDirectory.appendingPathComponent("seafile-animation.XXXXXX").path]
    let pipe = Pipe(); process.standardOutput = pipe
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw SeafileError.invalidResponse }
    return URL(fileURLWithPath: String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}
private func animationFixture(_ url: URL, frames: Int = 2) throws {
    let output = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil))
    CGImageDestinationSetProperties(output, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    let context = try #require(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 256,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    for index in 0..<frames {
        context.setFillColor(CGColor(red: index == 0 ? 1 : 0, green: 0, blue: index == 0 ? 0 : 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        CGImageDestinationAddImage(output, try #require(context.makeImage()), [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: index == 0 ? 0.2 : 0.4]] as CFDictionary)
    }
    #expect(CGImageDestinationFinalize(output))
}

private func partialFrameGIF() -> Data {
    // Original synthetic 3x1 GIF: red canvas, then a green 1x1 update at x=1.
    // Explicit LZW clears keep every code three bits wide.
    func codes(_ values: [UInt8]) -> [UInt8] {
        var bits: UInt32 = 0, count = 0; var bytes: [UInt8] = []
        for value in values {
            bits |= UInt32(value) << count; count += 3
            while count >= 8 { bytes.append(UInt8(bits & 255)); bits >>= 8; count -= 8 }
        }
        if count > 0 { bytes.append(UInt8(bits & 255)) }; return bytes
    }
    var gif: [UInt8] = Array("GIF89a".utf8) + [3,0,1,0,0x81,0,0] + [255,0,0,0,255,0,0,0,255,0,0,0]
    for (left, width, pixels) in [(UInt8(0), UInt8(3), [UInt8(0),0,0]), (1,1,[1])] {
        gif += [0x21,0xf9,4,4,30,0,0,0,0x2c,left,0,0,0,width,0,1,0,0,2]
        let bytes = codes(pixels.flatMap { [UInt8(4), $0] } + [5])
        gif += [UInt8(bytes.count)] + bytes + [0]
    }
    return Data(gif + [0x3b])
}

@Test func animationTimelineRespectsDifferentFrameDelaysAndFiniteRepetitions() throws {
    let once = try ImageAnimationTimeline(durations: [0.2, 0.4], repetitions: nil)
    #expect(once.position(at: 0.1).frame == 0)
    #expect(once.position(at: 0.3).frame == 1)
    #expect(once.position(at: 0.61).finished)
    let repeatOnce = try ImageAnimationTimeline(durations: [0.2, 0.4], repetitions: 1)
    #expect(repeatOnce.position(at: 0.7).frame == 0)
    #expect(!repeatOnce.position(at: 1.1).finished)
    #expect(repeatOnce.position(at: 1.21).finished)
    let forever = try ImageAnimationTimeline(durations: [0, .nan, .infinity, -1, 0.01], repetitions: 0)
    #expect(forever.durations == Array(repeating: 0.1, count: 5))
    #expect(!forever.position(at: 100).finished)
    #expect(forever.position(at: -.infinity).frame == 0)
    #expect(throws: Error.self) { try ImageAnimationTimeline(durations: [], repetitions: 0) }
    #expect(throws: Error.self) { try ImageAnimationTimeline(durations: [0.1], repetitions: -1) }
}

@Test func realGIFFramesDecodeDistinctBoundedImagesWithoutModifyingTheOriginal() async throws {
    let directory = try animationTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("actual.gif"); try animationFixture(file)
    let original = try Data(contentsOf: file)
    let frames = try #require(try AnimatedImageFrames(file: file))
    #expect(frames.timeline.durations == [0.2, 0.4]); #expect(frames.timeline.repetitions == 0)
    async let red = Task.detached { try frames.frame(at: 0, maximumPixelSize: 16) }.value
    async let blue = Task.detached { try frames.frame(at: 1, maximumPixelSize: 16) }.value
    let first = try await red, second = try await blue
    #expect(first.width <= 16 && first.height <= 16)
    #expect(second.width <= 16 && second.height <= 16)
    #expect(first.dataProvider?.data != second.dataProvider?.data)
    #expect(try Data(contentsOf: file) == original)
    #expect(throws: Error.self) { try frames.frame(at: 2) }
    #expect(throws: Error.self) { try frames.frame(at: 0, maximumPixelSize: 10_000) }
}

@Test func stillGIFAndInvalidFilesKeepTheStaticPreviewPath() throws {
    let directory = try animationTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("still.gif"); try animationFixture(file, frames: 1)
    #expect(try AnimatedImageFrames(file: file) == nil)
    try Data("invalid image fixture".utf8).write(to: file)
    #expect(try AnimatedImageFrames(file: file) == nil)
}

@Test func partialGIFFramesPreserveThePreviouslyDrawnCanvas() throws {
    let directory = try animationTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("partial.gif"), original = partialFrameGIF()
    try original.write(to: file)
    let animation = try #require(try AnimatedImageFrames(file: file))
    let image = try animation.frame(at: 1)
    #expect(image.width == 3 && image.height == 1)
    let context = try #require(CGContext(data: nil, width: 3, height: 1, bitsPerComponent: 8, bytesPerRow: 12,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: 3, height: 1))
    let pixels = Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self), count: 12))
    #expect(pixels == [255,0,0,255,0,255,0,255,255,0,0,255])
    #expect(try Data(contentsOf: file) == original)
}
