import Foundation
import Darwin
import ImageIO
import UniformTypeIdentifiers

public enum MotionPhotoComposer {
    /// Adds the standard directory without re-encoding the image or movie.
    /// Unsupported lossless metadata writes fail instead of silently converting
    /// HEIC/HDR into JPEG. The caller owns a private destination directory.
    public static func compose(photo: URL, video: URL, destination: URL) throws {
        try Task.checkCancellation()
        guard photo.isFileURL, video.isFileURL, destination.isFileURL,
              ![photo, video].contains(where: { $0.standardizedFileURL.resolvingSymlinksInPath() == destination.standardizedFileURL.resolvingSymlinksInPath() }),
              try MotionPhotoVideo.inspect(photo) == nil,
              let source = CGImageSourceCreateWithURL(photo as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) else { throw SeafileError.invalidResponse }
        let jpeg = type as String == UTType.jpeg.identifier
        guard jpeg || [UTType.heic.identifier, UTType.heif.identifier].contains(type as String) else {
            throw SeafileError.local("This photo format cannot be merged without changing its original image.")
        }
        let movieReader = try MotionPhotoReader(video)
        defer { try? movieReader.handle.close() }
        guard let movie = try movieReader.movie(offset: 0, length: movieReader.size) else { throw SeafileError.invalidResponse }
        let extended = movie.length > UInt64(UInt32.max) - 8, padding = jpeg ? 0 : (extended ? 16 : 8)
        let packet = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:Camera="http://ns.google.com/photos/1.0/camera/" xmlns:Container="http://ns.google.com/photos/1.0/container/" xmlns:Item="http://ns.google.com/photos/1.0/container/item/" Camera:MotionPhoto="1" Camera:MotionPhotoVersion="1" Camera:MotionPhotoPresentationTimestampUs="-1" Camera:MicroVideo="1" Camera:MicroVideoVersion="1" Camera:MicroVideoOffset="\(movie.length)"><Container:Directory><rdf:Seq><rdf:li rdf:parseType="Resource"><Container:Item Item:Mime="\(jpeg ? "image/jpeg" : "image/heic")" Item:Semantic="Primary" Item:Padding="\(padding)"/></rdf:li><rdf:li rdf:parseType="Resource"><Container:Item Item:Mime="\(movie.fileExtension == "mov" ? "video/quicktime" : "video/mp4")" Item:Semantic="MotionPhoto" Item:Length="\(movie.length)"/></rdf:li></rdf:Seq></Container:Directory></rdf:Description></rdf:RDF></x:xmpmeta>
        """
        guard let metadata = CGImageMetadataCreateFromXMPData(Data(packet.utf8) as CFData) else { throw SeafileError.invalidResponse }
        let output = try MotionPhotoOutput(destination)
        var completed = false
        defer { try? output.handle.close(); if !completed { try? FileManager.default.removeItem(at: destination) } }
        guard let consumer = output.consumer(), let writer = CGImageDestinationCreateWithDataConsumer(consumer, type, CGImageSourceGetCount(source), nil),
              CGImageDestinationCopyImageSource(writer, source, [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: true] as CFDictionary, nil), !output.failed else {
            throw SeafileError.local("The motion photo could not be merged losslessly. Both original resources are preserved.")
        }
        if !jpeg {
            let length = movie.length + UInt64(padding)
            try output.handle.write(contentsOf: MotionPhotoOutput.number(extended ? 1 : length, bytes: 4) + Data("mpvd".utf8)
                + (extended ? MotionPhotoOutput.number(length, bytes: 8) : Data()))
        }
        try movieReader.handle.seek(toOffset: 0)
        var remaining = movie.length
        while remaining > 0 {
            try Task.checkCancellation()
            guard let bytes = try movieReader.handle.read(upToCount: Int(min(remaining, 64 * 1024))), !bytes.isEmpty else { throw SeafileError.invalidResponse }
            try output.handle.write(contentsOf: bytes); remaining -= UInt64(bytes.count)
        }
        try output.handle.synchronize()
        guard let result = try MotionPhotoVideo.inspect(destination), result.length == movie.length else { throw SeafileError.invalidResponse }
        completed = true
    }
}

final class MotionPhotoOutput {
    let handle: FileHandle
    var failed = false
    init(_ destination: URL) throws {
        let fd = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SeafileError.local("The local destination already exists or cannot be written. Existing files were kept.") }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    func consumer() -> CGDataConsumer? {
        var callbacks = CGDataConsumerCallbacks(putBytes: { context, bytes, count in
            guard let context else { return 0 }
            let output = Unmanaged<MotionPhotoOutput>.fromOpaque(context).takeUnretainedValue()
            do { try output.handle.write(contentsOf: Data(bytes: bytes, count: count)); return count }
            catch { output.failed = true; return 0 }
        }, releaseConsumer: nil)
        return CGDataConsumer(info: Unmanaged.passUnretained(self).toOpaque(), cbks: &callbacks)
    }
    static func number(_ value: UInt64, bytes: Int) -> Data { Data((0..<bytes).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
}

/// A validated embedded movie range. Reads box headers and bounded metadata,
/// never the complete photo/movie into memory and never rewrites the source.
public struct MotionPhotoVideo: Sendable, Equatable {
    public let offset: UInt64
    public let length: UInt64
    public let fileExtension: String
    public private(set) var presentationTime: TimeInterval? = nil

    public static func inspect(_ file: URL) throws -> Self? {
        try Task.checkCancellation()
        guard file.isFileURL else { throw SeafileError.invalidResponse }
        let reader = try MotionPhotoReader(file)
        defer { try? reader.handle.close() }
        guard reader.size >= 16 else { return nil }
        let magic = try reader.read(0, count: 12)
        if magic.starts(with: [0xff, 0xd8]) {
            if let metadata = try reader.jpegMetadata() {
                guard let length = metadata.videoLength, length > 16, length <= reader.size else { return nil }
                let offset = reader.size - length
                guard offset > metadata.imageHeaderEnd else { return nil }
                var movie = try reader.movie(offset: offset, length: length)
                movie?.presentationTime = metadata.presentationTime
                return movie
            }
            // Preserve the original client's trailer-only JPEG compatibility,
            // but search only after a structurally parsed JPEG end marker.
            // An ftyp string inside EXIF or compressed pixels is never a movie.
            guard let end = try reader.jpegEnd(), end < reader.size else { return nil }
            return try reader.movie(offset: end, length: reader.size - end)
        }
        guard String(decoding: magic.dropFirst(4).prefix(4), as: UTF8.self) == "ftyp",
              let first = try reader.box(at: 0, limit: reader.size), first.size >= 16 else { return nil }
        let imageBrands = Set(["heic", "heix", "hevc", "hevx", "mif1", "msf1", "avif", "avis"])
        let brands = try reader.read(first.payload, count: Int(min(first.size - first.header, 1024)))
        guard stride(from: 0, to: max(0, brands.count - 3), by: 4).contains(where: {
            $0 != 4 && imageBrands.contains(String(decoding: brands[$0..<($0 + 4)], as: UTF8.self))
        }) else { return nil }
        var position: UInt64 = 0, seen = 0
        var xmp: MotionPhotoXMP?, imageMeta = false, imageData = false
        while position < reader.size {
            try Task.checkCancellation()
            guard seen < 100_000, let box = try reader.box(at: position, limit: reader.size) else { return nil }
            seen += 1
            imageMeta = imageMeta || box.type == "meta"; imageData = imageData || box.type == "mdat"
            if box.type == "uuid", box.size - box.header > 16, box.size - box.header <= 64 * 1024 + 16,
               try reader.read(box.payload, count: 16) == Data([0xbe,0x7a,0xcf,0xcb,0x97,0xa9,0x42,0xe8,0x9c,0x71,0x99,0x94,0x91,0xe3,0xaf,0xac]) {
                xmp = MotionPhotoXMP.parse(try reader.read(box.payload + 16, count: Int(box.size - box.header - 16)))
            }
            if box.type == "mpvd" {
                // mpvd must be the last box. Size zero is forbidden by the
                // Motion Photo format; do not mistake a random ftyp string for it.
                guard !box.toEnd, box.end == reader.size, reader.imageMotionEnabled(file) else { return nil }
                if let xmp, xmp.hasDeclaration, xmp.videoLength != box.size - box.header { return nil }
                var movie = try reader.movie(offset: box.payload, length: box.size - box.header)
                movie?.presentationTime = xmp?.presentationTime
                return movie
            }
            if position > 0, box.type == "ftyp", imageMeta, imageData, reader.imageMotionEnabled(file) {
                if let xmp, xmp.hasDeclaration, xmp.videoLength != reader.size - position { return nil }
                var movie = try reader.movie(offset: position, length: reader.size - position)
                movie?.presentationTime = xmp?.presentationTime
                return movie
            }
            position = box.end
        }
        return nil
    }

    /// Copies only the validated video into an explicitly provided owned path.
    /// Exclusive creation protects the original and any existing destination.
    public func copy(from source: URL, to destination: URL) throws {
        try Task.checkCancellation()
        guard source.isFileURL, destination.isFileURL,
              source.standardizedFileURL.resolvingSymlinksInPath() != destination.standardizedFileURL.resolvingSymlinksInPath(),
              try Self.inspect(source) == self else { throw SeafileError.invalidResponse }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let fd = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SeafileError.local("Could not create the local motion preview. Existing files were kept.") }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var completed = false
        defer { try? output.close(); if !completed { try? FileManager.default.removeItem(at: destination) } }
        try input.seek(toOffset: offset)
        var remaining = length
        while remaining > 0 {
            try Task.checkCancellation()
            guard let data = try input.read(upToCount: Int(min(remaining, 64 * 1024))), !data.isEmpty else { throw SeafileError.invalidResponse }
            try output.write(contentsOf: data); remaining -= UInt64(data.count)
        }
        try output.synchronize(); completed = true
    }
}

private final class MotionPhotoReader {
    struct Box {
        let offset: UInt64, size: UInt64, header: UInt64, type: String, toEnd: Bool
        var payload: UInt64 { offset + header }
        var end: UInt64 { offset + size }
    }
    let handle: FileHandle, size: UInt64
    init(_ file: URL) throws {
        handle = try FileHandle(forReadingFrom: file)
        do { size = try handle.seekToEnd() }
        catch { try? handle.close(); throw error }
    }
    func read(_ offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, offset <= size, UInt64(count) <= size - offset else { throw SeafileError.invalidResponse }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw SeafileError.invalidResponse }
        return data
    }
    func number(_ data: Data) -> UInt64 { data.reduce(0) { ($0 << 8) | UInt64($1) } }
    func imageMotionEnabled(_ file: URL) -> Bool {
        // Keep compatibility with older mpvd files without XMP, but honor an
        // editor's explicit MotionPhoto=0 regardless of the embedded movie.
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] else { return true }
        for tag in tags where CGImageMetadataTagCopyNamespace(tag) as String? == "http://ns.google.com/photos/1.0/camera/"
            && CGImageMetadataTagCopyName(tag) as String? == "MotionPhoto" {
            guard let value = CGImageMetadataTagCopyValue(tag), String(describing: value) == "1" else { return false }
        }
        return true
    }
    func box(at offset: UInt64, limit: UInt64) throws -> Box? {
        guard offset <= limit, limit <= size, limit - offset >= 8 else { return nil }
        let bytes = try read(offset, count: 8), short = number(bytes.prefix(4))
        var length = short, header: UInt64 = 8
        if short == 1 {
            guard limit - offset >= 16 else { return nil }
            length = number(try read(offset + 8, count: 8)); header = 16
        } else if short == 0 { length = limit - offset }
        guard length >= header, length <= limit - offset else { return nil }
        return Box(offset: offset, size: length, header: header, type: String(decoding: bytes.suffix(4), as: UTF8.self), toEnd: short == 0)
    }
    func movie(offset: UInt64, length: UInt64) throws -> MotionPhotoVideo? {
        guard offset <= size, length > 16, length <= size - offset else { return nil }
        let end = offset + length
        guard let first = try box(at: offset, limit: end), first.type == "ftyp", first.size >= first.header + 8 else { return nil }
        let brand = String(decoding: try read(first.payload, count: 4), as: UTF8.self)
        let videoBrands = Set(["isom", "iso2", "iso4", "iso5", "iso6", "mp41", "mp42", "avc1", "hvc1", "hev1", "M4V ", "qt  "])
        guard videoBrands.contains(brand) else { return nil }
        var position = first.end, seen = 0, movie = false, media = false
        while position < end {
            try Task.checkCancellation()
            guard seen < 100_000, let box = try box(at: position, limit: end) else { return nil }
            seen += 1; movie = movie || box.type == "moov"; media = media || (box.type == "mdat" && box.size > box.header)
            position = box.end
        }
        guard movie && media else { return nil }
        return MotionPhotoVideo(offset: offset, length: length, fileExtension: brand == "qt  " ? "mov" : "mp4")
    }
    func jpegMetadata() throws -> MotionPhotoXMP? {
        var position: UInt64 = 2, seen = 0, xmpSeen = false
        while position < size {
            try Task.checkCancellation()
            guard seen < 1024, size - position >= 4 else { return nil }
            let marker = try read(position, count: 2)
            guard marker.first == 0xff else { return nil }
            if marker.last == 0xff { position += 1; continue }
            if marker.last == 0xda || marker.last == 0xd9 { return xmpSeen ? MotionPhotoXMP.rejected() : nil }
            let length = number(try read(position + 2, count: 2))
            guard length >= 2, length <= size - position - 2 else { return nil }
            if marker.last == 0xe1 {
                let data = try read(position + 4, count: Int(length - 2))
                let prefix = Data("http://ns.adobe.com/xap/1.0/\0".utf8)
                xmpSeen = xmpSeen || data.starts(with: prefix)
                if data.starts(with: prefix), let metadata = MotionPhotoXMP.parse(Data(data.dropFirst(prefix.count))), metadata.hasDeclaration {
                    metadata.imageHeaderEnd = position + length + 2
                    return metadata
                }
            }
            position += length + 2; seen += 1
        }
        return xmpSeen ? MotionPhotoXMP.rejected() : nil
    }
    func jpegEnd() throws -> UInt64? {
        var position: UInt64 = 2, markers = 0
        while position < size {
            try Task.checkCancellation()
            guard markers < 100_000, size - position >= 4 else { return nil }
            let bytes = try read(position, count: 2)
            guard bytes.first == 0xff else { return nil }
            if bytes.last == 0xff { position += 1; continue }
            if bytes.last == 0xd9 { return position + 2 }
            let length = number(try read(position + 2, count: 2))
            guard length >= 2, length <= size - position - 2 else { return nil }
            let scan = bytes.last == 0xda
            position += length + 2; markers += 1
            if scan {
                var prefix: UInt64?, next: UInt64?
                while position < size, next == nil {
                    try Task.checkCancellation()
                    let chunk = try read(position, count: Int(min(size - position, 64 * 1024)))
                    for (index, byte) in chunk.enumerated() {
                        if let marker = prefix {
                            if byte == 0xff { continue }
                            if byte == 0 || (0xd0...0xd7).contains(byte) { prefix = nil; continue }
                            if byte == 0xd9 { return position + UInt64(index) + 1 }
                            next = marker; break
                        } else if byte == 0xff { prefix = position + UInt64(index) }
                    }
                    position += UInt64(chunk.count)
                }
                guard let next else { return nil }; position = next
            }
        }
        return nil
    }
}

private final class MotionPhotoXMP: NSObject, XMLParserDelegate {
    private static let camera = "http://ns.google.com/photos/1.0/camera/"
    private static let item = "http://ns.google.com/photos/1.0/container/item/"
    private var namespaces: [String: [String]] = [:]
    private var motion: Int?, micro: Int?, oldOffset: UInt64?
    private var timestamp: Int64?
    private var videoItems: [(UInt64?, String)] = []
    private var modernDirectorySeen = false, invalid = false
    private var depth = 0, directoryDepth: Int?, semantics: [String] = []
    private var property: String?, propertyText = ""
    private var itemDepth: Int?, itemValues: [String: String] = [:]
    private var itemProperty: String?, itemText = ""
    var imageHeaderEnd: UInt64 = 0
    var hasDeclaration: Bool { motion != nil || micro != nil || modernDirectorySeen || invalid }
    var presentationTime: TimeInterval? { timestamp.flatMap { $0 >= 0 ? Double($0) / 1_000_000 : nil } }
    static func rejected() -> MotionPhotoXMP { let result = MotionPhotoXMP(); result.invalid = true; return result }
    var videoLength: UInt64? {
        if motion == 0 || invalid { return nil }
        if motion == 1 {
            guard semantics.first == "Primary", semantics.filter({ $0 == "Primary" }).count == 1,
                  semantics.last == "MotionPhoto", videoItems.count == 1,
                  ["video/mp4", "video/quicktime"].contains(videoItems[0].1) else { return nil }
            return videoItems[0].0
        }
        // Compatibility with original Microvideo V1 files only when no modern
        // directory/flag is supplied; do not override MotionPhoto=0.
        return !modernDirectorySeen && motion == nil && micro == 1 ? oldOffset : nil
    }
    static func parse(_ data: Data) -> MotionPhotoXMP? {
        guard data.count <= 64 * 1024 else { return nil }
        // ImageIO includes the APP1 packet's terminating NUL. XML parsers
        // reject it; trim only trailing terminators, never bytes inside XML.
        var xml = data
        while xml.last == 0 { xml.removeLast() }
        guard let text = String(data: xml, encoding: .utf8), !text.uppercased().contains("<!DOCTYPE") else { return nil }
        let result = MotionPhotoXMP(), parser = XMLParser(data: xml)
        parser.shouldProcessNamespaces = true; parser.shouldReportNamespacePrefixes = true; parser.shouldResolveExternalEntities = false
        parser.delegate = result
        return parser.parse() ? result : nil
    }
    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) { namespaces[prefix, default: []].append(namespaceURI) }
    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) { _ = namespaces[prefix]?.popLast() }
    private func value(_ name: String, namespace: String, attributes: [String: String]) -> String? {
        attributes.first { key, _ in
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            return parts.count == 2 && parts[1] == name && namespaces[parts[0]]?.last == namespace
        }?.value
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        depth += 1
        guard depth <= 64 else { invalid = true; parser.abortParsing(); return }
        for name in ["MotionPhoto", "MicroVideo", "MicroVideoOffset", "MotionPhotoPresentationTimestampUs", "MicroVideoPresentationTimestampUs"] {
            if let value = value(name, namespace: Self.camera, attributes: attributes) { set(name, value) }
        }
        if namespaceURI == Self.camera, ["MotionPhoto", "MicroVideo", "MicroVideoOffset", "MotionPhotoPresentationTimestampUs", "MicroVideoPresentationTimestampUs"].contains(elementName) { property = elementName; propertyText = "" }
        if namespaceURI == "http://ns.google.com/photos/1.0/container/", elementName == "Directory" {
            if modernDirectorySeen { invalid = true }; modernDirectorySeen = true; directoryDepth = depth
        }
        if directoryDepth != nil, namespaceURI == "http://ns.google.com/photos/1.0/container/", elementName == "Item" {
            guard itemDepth == nil else { invalid = true; parser.abortParsing(); return }
            itemDepth = depth; itemValues = [:]
            for name in ["Semantic", "Length", "Mime"] {
                if let value = value(name, namespace: Self.item, attributes: attributes) { itemValues[name] = value }
            }
        }
        // ImageIO writes structured XMP properties as child elements; Google
        // camera files commonly use attributes. Both are the same RDF values.
        if let itemDepth, depth == itemDepth + 1, namespaceURI == Self.item, ["Semantic", "Length", "Mime"].contains(elementName) {
            itemProperty = elementName; itemText = ""
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if property != nil { propertyText += string; if propertyText.count > 128 { invalid = true; parser.abortParsing() } }
        if itemProperty != nil { itemText += string; if itemText.count > 128 { invalid = true; parser.abortParsing() } }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if namespaceURI == Self.camera, property == elementName { set(elementName, propertyText.trimmingCharacters(in: .whitespacesAndNewlines)); property = nil; propertyText = "" }
        if namespaceURI == Self.item, itemProperty == elementName {
            let value = itemText.trimmingCharacters(in: .whitespacesAndNewlines)
            if let old = itemValues[elementName], old != value { invalid = true }
            itemValues[elementName] = value; itemProperty = nil; itemText = ""
        }
        if itemDepth == depth {
            if let semantic = itemValues["Semantic"] {
                semantics.append(semantic)
                if semantic == "MotionPhoto" { videoItems.append((itemValues["Length"].flatMap { UInt64($0) }, itemValues["Mime"] ?? "")) }
            } else { invalid = true }
            itemDepth = nil; itemValues = [:]
        }
        if directoryDepth == depth { directoryDepth = nil }; depth -= 1
    }
    private func set(_ name: String, _ value: String) {
        switch name {
        case "MotionPhoto":
            let parsed = Int(value)
            if parsed != 0 && parsed != 1 || (motion != nil && motion != parsed) { invalid = true }
            motion = parsed
        case "MicroVideo": micro = Int(value)
        case "MicroVideoOffset": oldOffset = UInt64(value)
        case "MotionPhotoPresentationTimestampUs": timestamp = Int64(value)
        case "MicroVideoPresentationTimestampUs": if timestamp == nil { timestamp = Int64(value) }
        default: break
        }
    }
}
