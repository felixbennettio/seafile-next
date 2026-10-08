// Error messages ported from desktop/src/utils/seafile-error.cpp.
import Foundation

public enum SyncErrorDescription {
    public static func message(_ code: Int) -> String {
        switch code {
        case 0: String(localized: "File is locked by another application")
        case 1: String(localized: "Folder is locked by another application")
        case 2: String(localized: "File is locked by another user")
        case 3: String(localized: "Path is invalid")
        case 4: String(localized: "Error when indexing")
        case 5: String(localized: "Path ends with space or period character")
        case 6: String(localized: "Path contains invalid characters like '|' or ':'")
        case 7: String(localized: "Update to file denied by folder permission setting")
        case 8: String(localized: "Syncing is denied by cloud-only permission settings")
        case 9: String(localized: "Created or updated a file in a non-writable library or folder")
        case 10: String(localized: "Permission denied on server")
        case 11: String(localized: "Do not have write permission to the library")
        case 12: String(localized: "Storage quota full")
        case 13: String(localized: "Network error")
        case 14: String(localized: "Cannot resolve proxy address")
        case 15: String(localized: "Cannot resolve server address")
        case 16: String(localized: "Cannot connect to server")
        case 17: String(localized: "Failed to establish secure connection. Please check server SSL certificate")
        case 18: String(localized: "Data transfer was interrupted. Please check network or firewall")
        case 19: String(localized: "Data transfer timed out. Please check network or firewall")
        case 20: String(localized: "Unhandled http redirect from server. Please check server cofiguration")
        case 21: String(localized: "Server error")
        case 22: String(localized: "Internal data corrupt on the client. Please try to resync the library")
        case 23: String(localized: "Failed to write data on the client. Please check disk space or folder permissions")
        case 24: String(localized: "Library deleted on server")
        case 25: String(localized: "Library damaged on server")
        case 26: String(localized: "Not enough memory")
        case 27: String(localized: "Concurrent updates to file. File is saved as conflict file")
        case 28: String(localized: "Unknown error")
        case 29: String(localized: "No error")
        case 30: String(localized: "A folder that may contain not-yet-uploaded files is moved to seafile-recycle-bin folder.")
        case 31: String(localized: "The file path contains symbols that are not supported by the Windows system")
        case 32: String(localized: "Library cannot be synced since it has too many files.")
        case 33: String(localized: "Waiting for confirmation to delete files")
        case 34: String(localized: "Files cannot be uploaded to this library due to file number limit settings.")
        case 35: String(localized: "Failed to download file. Please check disk space or folder permissions")
        case 36: String(localized: "Failed to upload file blocks. Please check network or firewall")
        case 37: String(localized: "Path has character case conflict with existing file or folder. Will not be downloaded")
        case 38: String(localized: "Syncing is stopped by logout. Please re-sync the library if needed")
        case 39: String(localized: "Encryption key is corrupted. Please create a new library and upload files again")
        default: "Sync error \(code)"
        }
    }
}
