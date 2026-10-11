import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ImageAnimationTimeline: Sendable {
    public struct Position: Sendable, Equatable { public let frame: Int; public let finished: Bool }
    public let durations: [TimeInterval]
    public let repetitions: Int?
    public let duration: TimeInterval
    private let ends: [TimeInterval]
    public init(durations: [TimeInterval], repetitions: Int?) throws {
        guard !durations.isEmpty, durations.count <= 10_000 else { throw SeafileError.invalidResponse }
        if let repetitions, !(0...100_000).contains(repetitions) { throw SeafileError.invalidResponse }
        self.durations = durations.map { $0.isFinite && $0 > 0.011 ? min($0, 60) : 0.1 }
        self.repetitions = repetitions
        var total: TimeInterval = 0
        ends = self.durations.map { total += $0; return total }
        duration = total
    }
    /// GIF repetitions are additional runs; zero means continuous playback.
    public func position(at elapsed: TimeInterval) -> Position {
        let elapsed = elapsed.isFinite ? max(0, elapsed) : 0
        if repetitions != 0, elapsed >= duration * Double((repetitions ?? 0) + 1) {
            return Position(frame: durations.count - 1, finished: true)
        }
        let time = elapsed.truncatingRemainder(dividingBy: duration)
        var lower = 0, upper = ends.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if time < ends[middle] { upper = middle } else { lower = middle + 1 }
        }
        return Position(frame: min(lower, durations.count - 1), finished: false)
    }
}

/// One ImageIO reader guarded across decode tasks. It does not retain decoded
/// frames or load the whole file into Data; the UI keeps just the current frame.
public final class AnimatedImageFrames: @unchecked Sendable {
    public let timeline: ImageAnimationTimeline
    private let source: CGImageSource
    private let lock = NSLock()
    public init?(file: URL) throws {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.gif.identifier,
              CGImageSourceGetCount(source) > 1 else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count <= 10_000 else { throw SeafileError.local("This animation has too many frames to preview. You can still share the original file.") }
        let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let repetitions = (gif?[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue
        let delays = (0..<count).map { index -> TimeInterval in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            return ((gif?[kCGImagePropertyGIFUnclampedDelayTime] ?? gif?[kCGImagePropertyGIFDelayTime]) as? NSNumber)?.doubleValue ?? 0.1
        }
        timeline = try ImageAnimationTimeline(durations: delays, repetitions: repetitions)
        self.source = source
    }
    public func frame(at index: Int, maximumPixelSize: Int = 1536) throws -> CGImage {
        lock.lock(); defer { lock.unlock() }
        guard timeline.durations.indices.contains(index), (1...4096).contains(maximumPixelSize),
              let image = CGImageSourceCreateThumbnailAtIndex(source, index, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                kCGImageSourceShouldCache: false,
                kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw SeafileError.local("This animation frame could not be displayed. You can still share the original file.")
        }
        return image
    }
}
