import Darwin
import Foundation

enum FileLock {
    static func withExclusiveLock(at fileURL: URL, body: () throws -> Void) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let descriptor = open(fileURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Failed to open lock file at \(fileURL.path)"])
        }

        defer {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }

        guard flock(descriptor, LOCK_EX) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Failed to acquire exclusive lock at \(fileURL.path)"])
        }

        try body()
    }
}