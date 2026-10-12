import Foundation
import Darwin

/// An exclusively created private runtime workspace. Its last owner removes
/// extracted movies and paired copies after playback/PhotoKit has finished.
public final class MotionPhotoWorkspace: Sendable {
    public let directory: URL
    public init() throws {
        var template = Array(FileManager.default.temporaryDirectory.appendingPathComponent("seafile-motion.XXXXXX").path.utf8CString)
        let created = template.withUnsafeMutableBufferPointer { buffer in mkdtemp(buffer.baseAddress!) != nil }
        guard created else { throw SeafileError.local("A private motion photo workspace could not be created.") }
        directory = URL(fileURLWithPath: String(cString: template), isDirectory: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}
